"""Modular payment endpoints — optional Stripe billing plugin for Enterprise/SaaS deployments.

In self-hosted / OSS mode (IS_ENTERPRISE=false or no STRIPE_API_KEY), routes
gracefully return 501 Not Implemented and never import `stripe` or `supabase`
at module load time.
"""

import asyncio
import logging
from typing import Any

import sentry_sdk
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.config import get_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["payments"])


class CheckoutSessionRequest(BaseModel):
    plan: str


def _get_stripe() -> Any:
    """Lazy-import stripe so OSS/self-hosted installs don't require it at startup."""
    try:
        import stripe  # type: ignore[import-not-found]

        return stripe
    except ImportError as exc:
        raise HTTPException(
            status_code=501,
            detail="Stripe SDK is not installed in this environment.",
        ) from exc


def _verify_stripe_signature(
    payload: bytes, sig_header: str | None, webhook_secret: str
) -> dict[str, Any]:
    if not sig_header:
        raise HTTPException(status_code=400, detail="Missing Stripe signature")
    stripe = _get_stripe()
    try:
        return stripe.Webhook.construct_event(payload, sig_header, webhook_secret)
    except ValueError as exc:
        logger.error("Invalid Stripe payload")
        raise HTTPException(status_code=400, detail="Invalid payload") from exc
    except stripe.error.SignatureVerificationError as exc:
        logger.error("Invalid Stripe signature")
        raise HTTPException(status_code=400, detail="Invalid signature") from exc


def _activate_tenant_subscription(tenant_id: str | None, config: Any, redis: Any) -> None:
    if not tenant_id:
        return
    try:
        from supabase import Client, create_client

        supabase_client: Client = create_client(
            config.supabase_url, config.supabase_service_key
        )
        supabase_client.table("users").update({"is_subscribed": True}).eq(
            "id", tenant_id
        ).execute()
        logger.info(f"Database updated: user {tenant_id} is now subscribed.")

        async def _update_redis() -> None:
            await redis.setex(f"tenant:{tenant_id}:subscription_status", 86400, "true")

        asyncio.create_task(_update_redis())
    except Exception as e:
        sentry_sdk.capture_exception(e)
        logger.error(f"Failed to update database for tenant {tenant_id}: {e}")


def register_payment_routes(
    app_router: Any,
    get_tenant_id: Any,
    verify_infrastructure_access: Any,
    limiter: Any,
    config: Any,
) -> None:
    """Register payment routes with modular enterprise/self-hosted guards."""

    @app_router.post("/v1/payments/create-checkout-session")
    async def create_checkout_session(
        request: CheckoutSessionRequest, tenant_id: str = Depends(get_tenant_id)
    ) -> dict[str, Any]:
        active_config = get_config()
        if not getattr(active_config, "is_enterprise", False) or not active_config.stripe_api_key:
            raise HTTPException(
                status_code=501,
                detail="Billing is disabled in self-hosted / non-enterprise mode.",
            )
        stripe = _get_stripe()
        stripe.api_key = active_config.stripe_api_key
        base_url = getattr(active_config, "public_app_url", "http://localhost:3000").rstrip("/")
        try:
            unit_amount = 19000 if request.plan == "annual" else 1900
            plan_name = (
                "Veraxi Pro Annual"
                if request.plan == "annual"
                else "Veraxi Pro Monthly"
            )
            session = stripe.checkout.Session.create(
                line_items=[
                    {
                        "price_data": {
                            "currency": "usd",
                            "product_data": {"name": plan_name},
                            "unit_amount": unit_amount,
                        },
                        "quantity": 1,
                    }
                ],
                mode="payment",
                success_url=f"{base_url}/#/admin?success=true",
                cancel_url=f"{base_url}/#/admin?canceled=true",
                client_reference_id=tenant_id,
            )
            return {"checkout_url": session.url}
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Stripe error: {e}")
            raise HTTPException(status_code=500, detail=str(e)) from e

    @app_router.post("/admin/stripe-webhook")
    async def stripe_webhook(request: Request) -> dict[str, str]:
        """Receives payment success events from Stripe."""
        active_config = get_config()
        if not getattr(active_config, "is_enterprise", False) or not active_config.stripe_api_key:
            raise HTTPException(
                status_code=501,
                detail="Billing webhook is disabled in self-hosted mode.",
            )
        stripe = _get_stripe()
        stripe.api_key = active_config.stripe_api_key
        payload = await request.body()
        sig_header = request.headers.get("stripe-signature")
        event = _verify_stripe_signature(
            payload, sig_header, active_config.stripe_webhook_secret
        )
        if event["type"] == "checkout.session.completed":
            session = event["data"]["object"]
            tenant_id = session.get("client_reference_id")
            logger.info(
                f"STRIPE PAYMENT RECEIVED for tenant: {tenant_id}. Activating subscription."
            )
            _activate_tenant_subscription(
                tenant_id, active_config, request.app.state.redis
            )
        else:
            logger.info(f"Unhandled Stripe event type: {event['type']}")
        return {"status": "success"}
