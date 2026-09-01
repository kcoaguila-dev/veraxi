import os

from supabase import create_client

supabase_url = os.environ.get("SUPABASE_URL")
supabase_key = os.environ.get("SUPABASE_SERVICE_KEY")
client = create_client(supabase_url, supabase_key)

# We can't generate a token directly easily, but we can check if PyJWKClient can fetch the JWKS.
from jwt import PyJWKClient

jwks_url = f"{supabase_url}/auth/v1/.well-known/jwks.json"
try:
    jwks_client = PyJWKClient(jwks_url)
    keys = jwks_client.get_jwk_set()
    print("Successfully fetched JWKS! Found", len(keys.keys), "keys.")
except Exception as e:  # noqa: BLE001
    print("Error fetching JWKS:", e)
