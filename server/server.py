"""
Kibala C2PA Certificate Signing & Privacy Gateway Server
=========================================================

FastAPI server with two roles:

1. **Certificate Authority** — issues end-entity certificates to iOS devices
   (POST /api/v1/certificates/sign).

2. **Privacy Gateway** — receives device-signed C2PA photos, validates the
   manifest against our Root CA, strips all metadata (EXIF, XMP, JUMBF),
   and re-signs with the gateway's own certificate. The output contains
   ONLY the gateway's signature — the photographer is fully anonymized
   (POST /api/v1/publish).

Required end-entity certificate extensions for C2PA:
  - BasicConstraints(ca=False)                     -- not a CA
  - KeyUsage(digitalSignature=True)                -- signs content
  - ExtendedKeyUsage(emailProtection)              -- required by C2PA spec
  - SubjectKeyIdentifier                           -- identifies the cert's key
  - AuthorityKeyIdentifier                         -- links to issuing CA

Dependencies:
  pip install fastapi uvicorn cryptography c2pa-python python-multipart Pillow

Usage:
  1. Run generate_root_ca.py first (if you haven't already)
  2. python server.py
  3. Server listens on http://0.0.0.0:8080
"""

from fastapi import FastAPI, HTTPException, File, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel
from cryptography import x509
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
import c2pa
import datetime
import uuid
import os
import json
import tempfile
import shutil
from PIL import Image, ImageOps

app = FastAPI(title="Kibala C2PA CA & Gateway Server")

# --- Load Root CA ---
CERT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cert_key")

try:
    with open(os.path.join(CERT_DIR, "kibala_Root_CA.crt"), "rb") as f:
        root_cert = x509.load_pem_x509_certificate(f.read())
    with open(os.path.join(CERT_DIR, "kibala_Root_Key.pem"), "rb") as f:
        root_key = serialization.load_pem_private_key(f.read(), password=None)

    # Validate root CA has BasicConstraints ca=True
    try:
        bc = root_cert.extensions.get_extension_for_class(x509.BasicConstraints)
        if not bc.value.ca:
            print("⚠️  WARNING: Root CA does not have ca=True! Re-run generate_root_ca.py")
    except x509.ExtensionNotFound:
        print("⚠️  WARNING: Root CA missing BasicConstraints! Re-run generate_root_ca.py")

    print("✅ Root CA loaded successfully.")
    print(f"   Subject: {root_cert.subject}")
    print(f"   Valid until: {root_cert.not_valid_after_utc}")
except FileNotFoundError:
    print("❌ Root CA files not found! Run generate_root_ca.py first.")
    print(f"   Expected files in: {CERT_DIR}/")
    exit(1)


# --- Gateway End-Entity Certificate ---
# Generated at startup, signed by Root CA.
# Used by the /api/v1/publish endpoint to re-sign photos.

gateway_key = ec.generate_private_key(ec.SECP256R1())

gateway_cert = (
    x509.CertificateBuilder()
    .subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "imanmontajabi.com Gateway"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "imanmontajabi"),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "DE"),
    ]))
    .issuer_name(root_cert.subject)
    .public_key(gateway_key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.datetime.now(datetime.UTC) - datetime.timedelta(minutes=5))
    .not_valid_after(datetime.datetime.now(datetime.UTC) + datetime.timedelta(days=365))
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(
        x509.KeyUsage(
            digital_signature=True, content_commitment=False,
            key_encipherment=False, data_encipherment=False,
            key_agreement=False, key_cert_sign=False, crl_sign=False,
            encipher_only=False, decipher_only=False,
        ),
        critical=True,
    )
    .add_extension(
        x509.ExtendedKeyUsage([ExtendedKeyUsageOID.EMAIL_PROTECTION]),
        critical=False,
    )
    .add_extension(
        x509.SubjectKeyIdentifier.from_public_key(gateway_key.public_key()),
        critical=False,
    )
    .add_extension(
        x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()),
        critical=False,
    )
).sign(private_key=root_key, algorithm=hashes.SHA256())

# PEM certificate chain for c2pa signer: gateway EE cert → Root CA
gateway_cert_pem = gateway_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")
root_cert_pem = root_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")
gateway_chain_pem = gateway_cert_pem.strip() + "\n" + root_cert_pem.strip()

print("✅ Gateway certificate generated")
print(f"   Subject: {gateway_cert.subject}")

# --- Configure C2PA Trust Anchors ---
# Tell the c2pa library to validate signatures against our Root CA only.
# Photos NOT signed by a certificate issued by this Root CA will be rejected.
c2pa.load_settings({
    "verify": {
        "verify_cert_anchors": True,
    },
    "trust": {
        "trust_anchors": root_cert_pem,
    },
})
print("🔒 C2PA trust anchors configured (only our Root CA is trusted)")


def gateway_sign_callback(data: bytes) -> bytes:
    """Sign data with the gateway's EC P-256 private key (ES256)."""
    return gateway_key.sign(data, ec.ECDSA(hashes.SHA256()))


# --- Models ---

class SigningRequest(BaseModel):
    csr: str
    metadata: dict | None = None


class SigningResponse(BaseModel):
    certificate_chain: str
    certificate_id: str
    serial_number: str
    expires_at: str


# --- Endpoint ---

@app.post("/api/v1/certificates/sign", response_model=SigningResponse)
async def sign_csr(req: SigningRequest):
    try:
        csr = x509.load_pem_x509_csr(req.csr.encode("utf-8"))

        valid_from = datetime.datetime.now(datetime.UTC) - datetime.timedelta(minutes=5)
        valid_to = valid_from + datetime.timedelta(days=365)

        builder = (
            x509.CertificateBuilder()
            .subject_name(csr.subject)
            .issuer_name(root_cert.subject)
            .public_key(csr.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(valid_from)
            .not_valid_after(valid_to)
            # ---- Extensions required by C2PA ----
            #
            # 1. Not a CA
            .add_extension(
                x509.BasicConstraints(ca=False, path_length=None),
                critical=True,
            )
            # 2. Key usage: digital signatures only
            .add_extension(
                x509.KeyUsage(
                    digital_signature=True,
                    content_commitment=False,
                    key_encipherment=False,
                    data_encipherment=False,
                    key_agreement=False,
                    key_cert_sign=False,
                    crl_sign=False,
                    encipher_only=False,
                    decipher_only=False,
                ),
                critical=True,
            )
            # 3. Extended Key Usage — emailProtection is required by C2PA
            .add_extension(
                x509.ExtendedKeyUsage([ExtendedKeyUsageOID.EMAIL_PROTECTION]),
                critical=False,
            )
            # 4. Subject Key Identifier — identifies this cert's public key
            .add_extension(
                x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
                critical=False,
            )
            # 5. Authority Key Identifier — links to the issuing Root CA
            .add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_public_key(
                    root_key.public_key()
                ),
                critical=False,
            )
        )

        certificate = builder.sign(
            private_key=root_key,
            algorithm=hashes.SHA256(),
        )

        # Build the PEM chain: end-entity cert first, then root CA
        cert_pem = certificate.public_bytes(serialization.Encoding.PEM).decode("utf-8")
        root_pem = root_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")
        full_chain = cert_pem.strip() + "\n" + root_pem.strip()

        cert_id = str(uuid.uuid4())
        serial = str(certificate.serial_number)

        print(f"✅ Issued certificate {cert_id} (serial: {serial[:16]}...)")

        return SigningResponse(
            certificate_chain=full_chain,
            certificate_id=cert_id,
            serial_number=serial,
            expires_at=valid_to.isoformat(),
        )

    except Exception as e:
        print(f"❌ Error signing CSR: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# --- Publish (Redaction Gateway) Endpoint ---


@app.post("/api/v1/publish")
async def publish_photo(file: UploadFile = File(...)):
    """
    Privacy-preserving redaction gateway.

    Workflow: Validate → Strip → Re-sign

    1. Receives a device-signed C2PA JPEG.
    2. Validates the manifest against our Root CA trust anchor.
       - Rejects images that were NOT signed by a Kibala device.
    3. Strips ALL metadata (EXIF, XMP, JUMBF/C2PA, GPS, camera info)
       using Pillow, producing a clean JPEG with no provenance history.
    4. Signs the clean image with a fresh manifest using the gateway's
       certificate. The output shows ONLY the gateway's signature —
       the photographer's identity is completely anonymized.
    """
    temp_dir = tempfile.mkdtemp(prefix="kibala_gw_")
    try:
        # ── 1. Save uploaded file ──
        input_path = os.path.join(temp_dir, "input.jpg")
        content = await file.read()
        with open(input_path, "wb") as f:
            f.write(content)
        print(f"📥 Received upload: {len(content):,} bytes")

        # ── 2. Validate C2PA manifest against our Root CA ──
        try:
            with open(input_path, "rb") as f:
                with c2pa.Reader("image/jpeg", f) as reader:
                    manifest_json_str = reader.json()
                    manifest_store = json.loads(manifest_json_str)
        except Exception as e:
            raise HTTPException(
                status_code=400,
                detail=f"Cannot read C2PA manifest from uploaded image: {e}",
            )

        # 2a. Must contain at least one manifest
        if "manifests" not in manifest_store or not manifest_store["manifests"]:
            raise HTTPException(
                status_code=400,
                detail="Rejected: no C2PA manifests found in the uploaded image.",
            )

        # 2b. Must pass trust-anchor validation (our Root CA).
        #     If the c2pa library finds validation errors, it includes a
        #     "validation_status" array in the JSON. Its absence means valid.
        if "validation_status" in manifest_store:
            errors = manifest_store["validation_status"]
            print(f"❌ Validation failed: {json.dumps(errors, indent=2)}")
            raise HTTPException(
                status_code=403,
                detail=f"Rejected: C2PA validation failed — {errors}",
            )

        active_id = manifest_store.get("active_manifest", "unknown")
        print(f"✅ C2PA manifest validated against Root CA (active: {active_id})")

        # ── 3. Strip ALL metadata (anonymize) ──
        #
        # Pillow decodes the pixel data and re-encodes without any metadata:
        # - EXIF (camera model, serial number, GPS coordinates)
        # - XMP (editing history, author info)
        # - JUMBF/C2PA (the device's manifest & signature)
        # - IPTC (caption, keywords, photographer name)
        #
        # ICC profile is preserved for correct color rendering.
        img = Image.open(input_path)
        icc_profile = img.info.get("icc_profile")

        # Bake the EXIF Orientation tag into the actual pixel data BEFORE
        # stripping metadata.  Without this, removing EXIF loses the
        # orientation hint and the output appears rotated.
        img = ImageOps.exif_transpose(img)

        clean_path = os.path.join(temp_dir, "clean.jpg")
        save_kwargs = {"format": "JPEG", "quality": 100}
        if icc_profile:
            save_kwargs["icc_profile"] = icc_profile
        img.save(clean_path, **save_kwargs)
        img.close()

        clean_size = os.path.getsize(clean_path)
        print(f"🧹 Metadata stripped: {clean_size:,} bytes (clean JPEG)")

        # ── 4. Sign clean image with fresh gateway manifest ──
        timestamp = datetime.datetime.now(datetime.UTC).isoformat() + "Z"
        gateway_manifest = {
            "claim_generator": "imanmontajabi.com/1.0",
            "claim_generator_info": [
                {"name": "imanmontajabi.com", "version": "1.0"}
            ],
            "title": "imanmontajabi.com",
            "assertions": [
                {
                    "label": "c2pa.actions",
                    "data": {
                        "actions": [
                            {
                                "action": "c2pa.published",
                                "softwareAgent": "imanmontajabi.com/1.0",
                                "when": timestamp,
                            }
                        ]
                    },
                },
                {
                    "label": "stds.schema-org.CreativeWork",
                    "data": {
                        "@context": "http://schema.org",
                        "@type": "CreativeWork",
                        "author": [
                            {
                                "@type": "Organization",
                                "name": "imanmontajabi.com",
                            }
                        ],
                    },
                },
            ],
        }

        # No ingredients added — the original device manifest is NOT
        # carried forward.  The output will contain ONLY the gateway's
        # signature, effectively anonymizing the photographer.
        output_path = os.path.join(temp_dir, "published.jpg")

        with c2pa.Signer.from_callback(
            callback=gateway_sign_callback,
            alg=c2pa.C2paSigningAlg.ES256,
            certs=gateway_chain_pem,
        ) as signer:
            with c2pa.Builder(gateway_manifest) as builder:
                builder.sign_file(
                    source_path=clean_path,
                    dest_path=output_path,
                    signer=signer,
                )

        # ── 5. Return re-signed image ──
        with open(output_path, "rb") as f:
            signed_data = f.read()

        print(f"✅ Gateway published: {len(signed_data):,} bytes (only gateway signature)")

        return Response(
            content=signed_data,
            media_type="image/jpeg",
            headers={
                "Content-Disposition": 'attachment; filename="kibala_published.jpg"',
            },
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Gateway error: {e}")
        raise HTTPException(status_code=500, detail=str(e)) from e
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8080)
