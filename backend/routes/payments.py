"""Payment endpoints — Stripe checkout and webhooks."""

import asyncio
import logging

import sentry_sdk
import stripe
from backend.config import get_config
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from supabase import Client, create_client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["payments"])


class CheckoutSessionRequest(BaseModel):
    plan: str


def _verify_stripe_signature(payload: bytes, sig_header: str | None, webhook_secret: str) -> dict:
    if not sig_header:
        raise HTTPException(status_code=400, detail="Missing Stripe signature")
    try:
        return stripe.Webhook.construct_event(payload, sig_header, webhook_secret)
    except ValueError:
        logger.error("Invalid Stripe payload")
        raise HTTPException(status_code=400, detail="Invalid payload")
    except stripe.error.SignatureVerificationError:
        logger.error("Invalid Stripe signature")
        raise HTTPException(status_code=400, detail="Invalid signature")


def _activate_tenant_subscription(tenant_id: str | None, config, redis):
    if not tenant_id:
        return
    try:
        supabase_client: Client = create_client(config.supabase_url, config.supabase_service_key)
        supabase_client.table("users").update({"is_subscribed": True}).eq("id", tenant_id).execute()
        logger.info(f"Database updated: user {tenant_id} is now subscribed.")

        async def _update_redis():
            await redis.setex(f"tenant:{tenant_id}:subscription_status", 86400, "true")
        asyncio.create_task(_update_redis())
    except Exception as e:  # noqa: BLE001
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to update database for tenant {tenant_id}: {e}")


def register_payment_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all payment routes with injected auth dependencies."""

    @app_router.post("/v1/payments/create-checkout-session")
    async def create_checkout_session(request: CheckoutSessionRequest, tenant_id: str = Depends(get_tenant_id)):
        if not config.stripe_api_key:
            raise HTTPException(status_code=500, detail="Stripe is not configured on this server.")
        stripe.api_key = config.stripe_api_key
        try:
            unit_amount = 19000 if request.plan == 'annual' else 1900
            plan_name = "Veraxi Pro Annual" if request.plan == 'annual' else "Veraxi Pro Monthly"
            session = stripe.checkout.Session.create(
                payment_method_types=['card'],
                line_items=[{'price_data': {'currency': 'usd', 'product_data': {'name': plan_name}, 'unit_amount': unit_amount}, 'quantity': 1}],
                mode='payment',
                success_url="https://veraxi.me/#/admin?success=true",
                cancel_url="https://veraxi.me/#/admin?canceled=true",
                client_reference_id=tenant_id,
            )
            return {"checkout_url": session.url}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Stripe error: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/admin/stripe-webhook")
    async def stripe_webhook(request: Request):
        """Receives payment success events from Stripe."""
        config = get_config()
        stripe.api_key = config.stripe_api_key
        payload = await request.body()
        sig_header = request.headers.get("stripe-signature")
        event = _verify_stripe_signature(payload, sig_header, config.stripe_webhook_secret)
        if event['type'] == 'checkout.session.completed':
            session = event['data']['object']
            tenant_id = session.get('client_reference_id')
            logger.info(f"💰 STRIPE PAYMENT RECEIVED for tenant: {tenant_id}! Activate their subscription.")
            _activate_tenant_subscription(tenant_id, config, request.app.state.redis)
        else:
            logger.info(f"Unhandled Stripe event type: {event['type']}")
        return {"status": "success"}
