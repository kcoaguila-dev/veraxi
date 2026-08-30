import os
import sys
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

url = os.environ.get("SUPABASE_URL")
key = os.environ.get("SUPABASE_SERVICE_KEY")

if not url or not key:
    print("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set.")
    sys.exit(1)

supabase: Client = create_client(url, key)

EMAIL = "e2e_tester@veraxi.me"
PASSWORD = "e2e_test_password_123"

def setup_user():
    print(f"Setting up E2E user: {EMAIL}")
    try:
        # Check if user exists by trying to sign in
        # Wait, admin API doesn't have list users easily without pagination.
        # We can just try to create the user with admin API.
        try:
            res = supabase.auth.admin.create_user({
                "email": EMAIL,
                "password": PASSWORD,
                "email_confirm": True
            })
            print("User created successfully.")
        except Exception as e:
            if "already registered" in str(e).lower() or "already exists" in str(e).lower() or "already been registered" in str(e).lower():
                print("User already exists. Updating password to ensure it matches.")
                users = supabase.auth.admin.list_users()
                user = next((u for u in users if u.email == EMAIL), None)
                if user:
                    supabase.auth.admin.update_user_by_id(
                        user.id,
                        {"password": PASSWORD, "email_confirm": True}
                    )
                    print("User password updated successfully.")
                else:
                    print(f"Failed to find existing user {EMAIL} to update.")
            else:
                raise e
    except Exception as e:
        print(f"Error setting up E2E user: {e}")
        sys.exit(1)

if __name__ == "__main__":
    setup_user()
