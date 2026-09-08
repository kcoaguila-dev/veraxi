"""TTS endpoints — voice listing, upload, and audio synthesis."""

import logging
import os
import shutil

import sentry_sdk
from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["tts"])


class VoiceListResponse(BaseModel):
    voices: list[dict]


class VoiceSaveRequest(BaseModel):
    voices: list[dict]


class AudioRequest(BaseModel):
    text: str
    voice_id: str
    message_id: str | None = None


def register_tts_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all TTS routes with injected auth dependencies."""

    @app_router.get("/api/voices", response_model=VoiceListResponse)
    async def get_voices(gpt_sovits_url: str | None = None):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_all_voices
        if gpt_sovits_url:
            client = GPTSoVITSClient(base_url=gpt_sovits_url)
            try:
                await client.check_connection()
            except Exception as e:  # noqa: BLE001
                raise HTTPException(status_code=503, detail=f"GPT-SoVITS instance unreachable: {e!s}")
            finally:
                await client.close()
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices", response_model=VoiceListResponse)
    async def save_voices(request: VoiceSaveRequest):
        from backend.tts.voices import get_all_voices
        from backend.tts.voices import save_voices as save_voices_to_disk
        try:
            save_voices_to_disk(request.voices)
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail=str(e))
        return {"voices": get_all_voices()}

    @app_router.post("/api/voices/upload", response_model=VoiceListResponse)
    async def upload_voice(name: str = Form(...), prompt_text: str = Form(...), file: UploadFile = File(...)):  # noqa: B008
        from backend.tts.voices import add_voice, get_all_voices
        try:
            voices_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tts", "voices")
            os.makedirs(voices_dir, exist_ok=True)
            safe_filename = file.filename.replace(" ", "_")
            file_path = os.path.join(voices_dir, safe_filename)
            with open(file_path, "wb") as buffer:  # noqa: ASYNC230
                shutil.copyfileobj(file.file, buffer)
            voice_id = safe_filename.rsplit(".", 1)[0].lower()
            ref_audio_path = f"voices/{safe_filename}"
            add_voice(voice_id=voice_id, name=name, ref_audio_path=ref_audio_path, prompt_text=prompt_text)
            return {"voices": get_all_voices()}
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Error uploading voice: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    @app_router.get("/api/chat/audio/{message_id}")
    async def get_audio(message_id: str):
        cache_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tts", "cache")
        cached_file_path = os.path.join(cache_dir, f"{message_id}.wav")
        if os.path.exists(cached_file_path):
            return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")
        raise HTTPException(status_code=404, detail="Audio not found")

    @app_router.post("/api/chat/audio")
    async def chat_audio(request: AudioRequest, req: Request):
        from backend.tts.gpt_sovits_client import GPTSoVITSClient
        from backend.tts.voices import get_voice
        if request.message_id:
            cache_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tts", "cache")
            os.makedirs(cache_dir, exist_ok=True)
            cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
            if os.path.exists(cached_file_path):
                logger.info(f"Returning cached audio for message {request.message_id}")
                return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")
        voice = get_voice(request.voice_id)
        if not voice:
            raise HTTPException(status_code=400, detail="Invalid voice ID")
        if not voice.get("ref_audio_path") or not voice.get("prompt_text"):
            raise HTTPException(status_code=400, detail="Voice not configured for backend synthesis")
        gpt_sovits_url = req.headers.get("x-gpt-sovits-url")
        client = GPTSoVITSClient(base_url=gpt_sovits_url)
        try:
            audio_bytes = await client.synthesize(text=request.text, ref_audio_path=voice["ref_audio_path"], prompt_text=voice["prompt_text"], prompt_lang=voice.get("prompt_lang", "en"), text_lang=voice.get("text_lang", "en"))
            if request.message_id:
                import asyncio
                from pathlib import Path
                cache_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "tts", "cache")
                os.makedirs(cache_dir, exist_ok=True)
                cached_file_path = os.path.join(cache_dir, f"{request.message_id}.wav")
                await asyncio.to_thread(Path(cached_file_path).write_bytes, audio_bytes)
                from backend.tts.cache_manager import cleanup_audio_cache
                cleanup_audio_cache(cache_dir, max_files=100, max_age_hours=24)
                return FileResponse(cached_file_path, media_type="audio/wav", filename="audio.wav")
            return StreamingResponse(iter([audio_bytes]), media_type="audio/wav", headers={"Content-Disposition": "attachment; filename=audio.wav"})
        except Exception as e:  # noqa: BLE001
            sentry_sdk.capture_exception(e)
            logger.error(f"Failed to synthesize audio: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to synthesize audio: {e!s}")
        finally:
            await client.close()
