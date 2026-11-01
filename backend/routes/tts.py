"""TTS endpoints — voice listing, upload, and audio synthesis."""

import asyncio
import glob
import hashlib
import ipaddress
import logging
import os
import re
import shutil
from html import unescape
from pathlib import Path
from urllib.parse import urlparse

import emoji
import sentry_sdk
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["tts"])


def _validate_tts_url(url: str, is_enterprise: bool = False) -> str:
    """Validate user-provided custom TTS base URL to prevent SSRF attacks."""
    if not url:
        return url
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid TTS URL scheme: {parsed.scheme}. Only HTTP/HTTPS are allowed.",
        )
    hostname = parsed.hostname
    if not hostname:
        raise HTTPException(status_code=400, detail="Invalid TTS URL: missing host")

    lower_host = hostname.lower()
    # Unconditionally block cloud metadata and link-local endpoints
    if lower_host in ("metadata.google.internal", "metadata", "instance-data"):
        raise HTTPException(status_code=400, detail="Disallowed TTS endpoint URL")

    try:
        ip = ipaddress.ip_address(lower_host)
        # Block link-local (e.g. 169.254.169.254 AWS/GCP metadata), unspecified (0.0.0.0)
        if ip.is_link_local or ip.is_unspecified:
            raise HTTPException(status_code=400, detail="Disallowed TTS endpoint URL")
        # In enterprise deployment, also forbid private and loopback networks
        if is_enterprise and (ip.is_private or ip.is_loopback):
            raise HTTPException(status_code=400, detail="Disallowed TTS endpoint URL")
    except ValueError:
        # Not a raw IP address; check hostname
        if lower_host == "localhost" and is_enterprise:
            raise HTTPException(status_code=400, detail="Disallowed TTS endpoint URL")

    return url


def clean_text_for_tts(text: str) -> str:
    """Convert assistant Markdown into natural speech text.

    TTS engines should receive what the user sees, not Markdown syntax such as
    emphasis markers, link destinations, or code fences.
    """
    # Keep code content readable while removing fenced-block decoration.
    text = re.sub(r"```(?:[\w+-]+)?\s*", "", text)
    text = text.replace("```", "")
    text = re.sub(r"`([^`]+)`", r"\1", text)
    # Keep link text and discard destinations; images are omitted entirely.
    text = re.sub(r"!\[[^\]]{0,1000}\]\([^)]{0,1000}\)", "", text)
    text = re.sub(r"\[([^\]]{1,1000})\]\([^)]{0,1000}\)", r"\1", text)
    text = re.sub(r"<https?://[^>]{1,1000}>", "", text)
    # Remove block-level and emphasis syntax without altering the words.
    text = re.sub(r"^\s{0,3}#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s{0,3}>\s?", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*\d+[.)]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"\*{1,3}|_{1,3}|~~", "", text)
    text = re.sub(r"^\s*[-|:]{3,}\s*$", "", text, flags=re.MULTILINE)
    text = unescape(text)
    # Remove common kaomojis
    kaomojis = r"(>[wW]<|[uU]w[uU]|[oO]w[oO]|\^_\^|~_\~|>_>|<_<|T_T|;_;|\^\^|;w;|-_-)"
    text = re.sub(kaomojis, "", text)
    # Remove all standard emojis
    text = emoji.replace_emoji(text, replace="")
    # Clean up double spaces
    return re.sub(r"\s+", " ", text).strip()


def safe_join(directory: str, *pathnames: str) -> str:
    """Safely join zero or more untrusted path components to a base directory."""
    final_path = os.path.abspath(os.path.join(directory, *pathnames))
    if not final_path.startswith(os.path.abspath(directory) + os.sep):
        raise HTTPException(status_code=400, detail="Path traversal detected")
    return final_path


class VoiceListResponse(BaseModel):
    voices: list[dict]


class VoiceSaveRequest(BaseModel):
    voices: list[dict]


class AudioRequest(BaseModel):
    text: str
    voice_id: str
    message_id: str | None = None


class FishAudioRequest(BaseModel):
    text: str
    reference_id: str | None = None
    message_id: str | None = None
    model: str | None = None


def register_tts_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all TTS routes with injected auth dependencies."""

    @app_router.get("/api/voices", response_model=VoiceListResponse)
    async def get_voices(
        gpt_sovits_url: str | None = None,
        _tenant_id: str = Depends(get_tenant_id),
    ):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_all_voices

        if gpt_sovits_url:
            gpt_sovits_url = _validate_tts_url(
                gpt_sovits_url, is_enterprise=config.is_enterprise
            )
            client = GPTSoVITSClient(base_url=gpt_sovits_url)
            try:
                await client.check_connection()
            except Exception as e:
                logger.warning(f"GPT-SoVITS instance unreachable: {e!s}")
            finally:
                await client.close()
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices", response_model=VoiceListResponse)
    async def save_voices(
        request: VoiceSaveRequest,
        _tenant_id: str = Depends(get_tenant_id),
    ):
        from backend.tts.voices import get_all_voices
        from backend.tts.voices import save_voices as save_voices_to_disk

        try:
            await asyncio.to_thread(save_voices_to_disk, request.voices)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices/upload", response_model=VoiceListResponse)
    async def upload_voice(
        name: str = Form(...),
        prompt_text: str = Form(...),
        file: UploadFile = File(...),  # noqa: B008
        _tenant_id: str = Depends(get_tenant_id),
    ):
        from backend.tts.voices import add_voice, get_all_voices

        try:
            voices_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "voices"
            )
            os.makedirs(voices_dir, exist_ok=True)
            safe_filename = (file.filename or "audio.wav").replace(" ", "_")
            file_path = safe_join(voices_dir, safe_filename)

            def _write_voice_file():
                with open(file_path, "wb") as buffer:
                    shutil.copyfileobj(file.file, buffer)

            await asyncio.to_thread(_write_voice_file)
            voice_id = safe_filename.rsplit(".", 1)[0].lower()
            ref_audio_path = f"voices/{safe_filename}"
            await asyncio.to_thread(
                add_voice,
                voice_id=voice_id,
                name=name,
                ref_audio_path=ref_audio_path,
                prompt_text=prompt_text,
            )
            return {"voices": get_all_voices()}
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Error uploading voice: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.post("/api/chat/audio/fish")
    async def chat_audio_fish(
        request: FishAudioRequest,
        req: Request,
        _tenant_id: str = Depends(get_tenant_id),
    ):
        import httpx

        fish_api_key = req.headers.get("x-fish-audio-key")
        fish_speech_url = req.headers.get("x-fish-speech-url")

        if not fish_speech_url and not fish_api_key:
            raise HTTPException(status_code=401, detail="Fish Audio API key missing")

        if fish_speech_url:
            fish_speech_url = _validate_tts_url(
                fish_speech_url, is_enterprise=config.is_enterprise
            )

        model = request.model or "s2.1-pro-free"
        cache_key = f"{request.reference_id or 'default'}_{model}"
        cache_hash = hashlib.sha256(cache_key.encode()).hexdigest()

        if request.message_id:
            cache_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
            )
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = safe_join(
                cache_dir, f"{request.message_id}_{cache_hash}.wav"
            )
            if os.path.exists(cached_file_path):
                return FileResponse(
                    cached_file_path, media_type="audio/wav", filename="audio.wav"
                )

        cleaned_text = clean_text_for_tts(request.text)
        payload = {"text": cleaned_text, "format": "wav"}
        if request.reference_id:
            payload["reference_id"] = request.reference_id

        target_url = (
            fish_speech_url if fish_speech_url else "https://api.fish.audio/v1/tts"
        )
        headers = {"Content-Type": "application/json"}
        if not fish_speech_url:
            headers["Authorization"] = f"Bearer {fish_api_key}"
            headers["model"] = model

        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    target_url, headers=headers, json=payload, timeout=30.0
                )
                if resp.status_code != 200:
                    raise HTTPException(status_code=resp.status_code, detail=resp.text)

                audio_bytes = resp.content

                if request.message_id:
                    cache_dir = os.path.join(
                        os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
                    )
                    os.makedirs(cache_dir, exist_ok=True)
                    cached_file_path = safe_join(
                        cache_dir, f"{request.message_id}_{cache_hash}.wav"
                    )
                    await asyncio.to_thread(
                        Path(cached_file_path).write_bytes, audio_bytes
                    )
                    from backend.tts.cache_manager import cleanup_audio_cache

                    cleanup_audio_cache(cache_dir, max_files=100, max_age_hours=24)
                    return FileResponse(
                        cached_file_path, media_type="audio/wav", filename="audio.wav"
                    )
                return StreamingResponse(
                    iter([audio_bytes]),
                    media_type="audio/wav",
                    headers={"Content-Disposition": "attachment; filename=audio.wav"},
                )
        except HTTPException:
            raise
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Failed to synthesize Fish audio: {e}")
            raise HTTPException(
                status_code=500, detail=f"Failed to synthesize Fish audio: {e!s}"
            )

    @app_router.get("/api/chat/audio/{message_id}")
    async def get_audio(
        message_id: str,
        _tenant_id: str = Depends(get_tenant_id),
    ):
        cache_dir = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
        )
        if not os.path.exists(cache_dir):
            raise HTTPException(status_code=404, detail="Audio not found")

        # 1. Exact match message_id.wav
        try:
            exact_file = safe_join(cache_dir, f"{message_id}.wav")
            if os.path.exists(exact_file):
                return FileResponse(
                    exact_file, media_type="audio/wav", filename="audio.wav"
                )
        except HTTPException:
            pass

        # 2. Hashed file match: {message_id}_{hash}.wav
        if "/" not in message_id and "\\" not in message_id and ".." not in message_id:
            matches = glob.glob(os.path.join(cache_dir, f"{message_id}_*.wav"))
            if matches:
                newest_match = max(matches, key=os.path.getmtime)
                return FileResponse(
                    newest_match, media_type="audio/wav", filename="audio.wav"
                )

        raise HTTPException(status_code=404, detail="Audio not found")

    @app_router.post("/api/chat/audio")
    async def chat_audio(
        request: AudioRequest,
        req: Request,
        _tenant_id: str = Depends(get_tenant_id),
    ):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_voice

        cache_key = request.voice_id
        cache_hash = hashlib.sha256(cache_key.encode()).hexdigest()

        if request.message_id:
            cache_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
            )
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = safe_join(
                cache_dir, f"{request.message_id}_{cache_hash}.wav"
            )
            if os.path.exists(cached_file_path):
                logger.info(f"Returning cached audio for message {request.message_id}")
                return FileResponse(
                    cached_file_path, media_type="audio/wav", filename="audio.wav"
                )
        voice = get_voice(request.voice_id)
        if not voice:
            raise HTTPException(status_code=400, detail="Invalid voice ID")
        if not voice.get("ref_audio_path") or not voice.get("prompt_text"):
            raise HTTPException(
                status_code=400, detail="Voice not configured for backend synthesis"
            )
        gpt_sovits_url = req.headers.get("x-gpt-sovits-url")
        if gpt_sovits_url:
            gpt_sovits_url = _validate_tts_url(
                gpt_sovits_url, is_enterprise=config.is_enterprise
            )
        client = GPTSoVITSClient(base_url=gpt_sovits_url)
        cleaned_text = clean_text_for_tts(request.text)
        try:
            audio_bytes = await client.synthesize(
                text=cleaned_text,
                ref_audio_path=voice["ref_audio_path"],
                prompt_text=voice["prompt_text"],
                prompt_lang=voice.get("prompt_lang", "en"),
                text_lang=voice.get("text_lang", "en"),
            )
            if request.message_id:
                cache_dir = os.path.join(
                    os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
                )
                os.makedirs(cache_dir, exist_ok=True)
                cached_file_path = safe_join(
                    cache_dir, f"{request.message_id}_{cache_hash}.wav"
                )
                await asyncio.to_thread(Path(cached_file_path).write_bytes, audio_bytes)
                from backend.tts.cache_manager import cleanup_audio_cache

                cleanup_audio_cache(cache_dir, max_files=100, max_age_hours=24)
                return FileResponse(
                    cached_file_path, media_type="audio/wav", filename="audio.wav"
                )
            return StreamingResponse(
                iter([audio_bytes]),
                media_type="audio/wav",
                headers={"Content-Disposition": "attachment; filename=audio.wav"},
            )
        except Exception as e:
            sentry_sdk.capture_exception(e)
            logger.error(f"Failed to synthesize audio: {e}")
            raise HTTPException(
                status_code=500, detail=f"Failed to synthesize audio: {e!s}"
            )
        finally:
            await client.close()
