"""TTS endpoints — voice listing, upload, and audio synthesis."""

import logging
import os
import shutil

import re

import emoji
import sentry_sdk
from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["tts"])


def clean_text_for_tts(text: str) -> str:
    """Remove emojis and kaomojis that confuse TTS engines."""
    # Remove common kaomojis
    kaomojis = r'(>[wW]<|[uU]w[uU]|[oO]w[oO]|\^_\^|~_\~|>_>|<_<|T_T|;_;|\^\^|;w;|-_-)'
    text = re.sub(kaomojis, '', text)
    # Remove all standard emojis
    text = emoji.replace_emoji(text, replace='')
    # Clean up double spaces
    return re.sub(r'\s+', ' ', text).strip()


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


def register_tts_routes(
    app_router, get_tenant_id, verify_infrastructure_access, limiter, config
):
    """Register all TTS routes with injected auth dependencies."""

    @app_router.get("/api/voices", response_model=VoiceListResponse)
    async def get_voices(gpt_sovits_url: str | None = None):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_all_voices

        if gpt_sovits_url:
            client = GPTSoVITSClient(base_url=gpt_sovits_url)
            try:
                await client.check_connection()
            except Exception as e:
                logger.warning(f"GPT-SoVITS instance unreachable: {e!s}")
            finally:
                await client.close()
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices", response_model=VoiceListResponse)
    async def save_voices(request: VoiceSaveRequest):
        from backend.tts.voices import get_all_voices
        from backend.tts.voices import save_voices as save_voices_to_disk

        try:
            save_voices_to_disk(request.voices)
        except Exception as e:
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices/upload", response_model=VoiceListResponse)
    async def upload_voice(
        name: str = Form(...),
        prompt_text: str = Form(...),
        file: UploadFile = File(...),  # noqa: B008
    ):
        from backend.tts.voices import add_voice, get_all_voices

        try:
            voices_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "voices"
            )
            os.makedirs(voices_dir, exist_ok=True)
            safe_filename = (file.filename or "audio.wav").replace(" ", "_")
            file_path = os.path.join(voices_dir, safe_filename)
            with open(file_path, "wb") as buffer:  # noqa: ASYNC230
                shutil.copyfileobj(file.file, buffer)
            voice_id = safe_filename.rsplit(".", 1)[0].lower()
            ref_audio_path = f"voices/{safe_filename}"
            add_voice(
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
    async def chat_audio_fish(request: FishAudioRequest, req: Request):
        import asyncio
        from pathlib import Path

        import httpx

        fish_api_key = req.headers.get("x-fish-audio-key")
        fish_speech_url = req.headers.get("x-fish-speech-url")

        if not fish_speech_url and not fish_api_key:
            raise HTTPException(status_code=401, detail="Fish Audio API key missing")

        if request.message_id:
            cache_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
            )
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
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
            headers["model"] = "s2.1-pro-free"

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
                    cached_file_path = os.path.join(
                        cache_dir, f"{request.message_id}.wav"
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
    async def get_audio(message_id: str):
        cache_dir = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
        )
        cached_file_path = os.path.join(cache_dir, f"{message_id}.wav")
        if os.path.exists(cached_file_path):
            return FileResponse(
                cached_file_path, media_type="audio/wav", filename="audio.wav"
            )
        raise HTTPException(status_code=404, detail="Audio not found")

    @app_router.post("/api/chat/audio")
    async def chat_audio(request: AudioRequest, req: Request):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_voice

        if request.message_id:
            cache_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
            )
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
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
                import asyncio
                from pathlib import Path

                cache_dir = os.path.join(
                    os.path.dirname(os.path.dirname(__file__)), "tts", "cache"
                )
                os.makedirs(cache_dir, exist_ok=True)
                cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
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
