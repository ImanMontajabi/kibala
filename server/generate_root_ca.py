#!/usr/bin/env python3
"""
Generate a proper Root CA certificate and private key for Kibala C2PA signing.

The C2PA standard requires:
  - Root CA with BasicConstraints(ca=True) and KeyUsage(keyCertSign, crlSign)
  - SubjectKeyIdentifier on the root
  - The signing algorithm must be ECDSA with SHA-256 (P-256 curve) to match
    the Secure Enclave's ES256 key.

Run this script ONCE to create:
  - cert_key/kibala_Root_CA.crt  (PEM-encoded root certificate)
  - cert_key/kibala_Root_Key.pem (PEM-encoded root private key, UNENCRYPTED)

Then restart your FastAPI server.
"""

import os
import datetime
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cert_key")
CERT_PATH = os.path.join(OUTPUT_DIR, "kibala_Root_CA.crt")
KEY_PATH = os.path.join(OUTPUT_DIR, "kibala_Root_Key.pem")

VALIDITY_DAYS = 3650  # 10 years


def generate():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Generate an EC P-256 private key (matches ES256 / Secure Enclave)
    root_key = ec.generate_private_key(ec.SECP256R1())

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "DE"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Lower Saxony"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Osnabrueck"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Kibala"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Kibala Root CA"),
    ])

    now = datetime.datetime.now(datetime.UTC)

    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(root_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=VALIDITY_DAYS))
        # --- Critical CA extensions ---
        .add_extension(
            x509.BasicConstraints(ca=True, path_length=None),
            critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,   # Required: this CA signs end-entity certs
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()),
            critical=False,
        )
    )

    root_cert = builder.sign(
        private_key=root_key,
        algorithm=hashes.SHA256(),
    )

    # Write private key (unencrypted - for development only!)
    with open(KEY_PATH, "wb") as f:
        f.write(
            root_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
    print(f"✅ Root CA private key written to: {KEY_PATH}")

    # Write certificate
    with open(CERT_PATH, "wb") as f:
        f.write(root_cert.public_bytes(serialization.Encoding.PEM))
    print(f"✅ Root CA certificate written to: {CERT_PATH}")

    # Print summary
    print(f"\n📜 Subject: {root_cert.subject}")
    print(f"📅 Valid from: {root_cert.not_valid_before_utc}")
    print(f"📅 Valid until: {root_cert.not_valid_after_utc}")
    print(f"🔑 Key type: EC P-256 (matches Secure Enclave ES256)")
    print(f"\n⚠️  Now restart your FastAPI server so it loads the new Root CA.")
    print(f"⚠️  In the iOS app, tap 'Reset Keys' to clear the old cached certificate.")


if __name__ == "__main__":
    generate()
