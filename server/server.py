"""
Kibala C2PA Certificate Signing Server
=======================================

FastAPI server that acts as a local Certificate Authority.
Receives CSRs from the iOS app and returns signed end-entity certificates
with the extensions required by the C2PA standard.

Required end-entity certificate extensions for C2PA:
  - BasicConstraints(ca=False)                     -- not a CA
  - KeyUsage(digitalSignature=True)                -- signs content
  - ExtendedKeyUsage(emailProtection)              -- required by C2PA spec
  - SubjectKeyIdentifier                           -- identifies the cert's key
  - AuthorityKeyIdentifier                         -- links to issuing CA

Usage:
  1. Run generate_root_ca.py first (if you haven't already)
  2. python server.py
  3. Server listens on http://0.0.0.0:8080
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from cryptography import x509
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.x509.oid import ExtendedKeyUsageOID
import datetime
import uuid
import os

app = FastAPI(title="Kibala C2PA CA Server")

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


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8080)
