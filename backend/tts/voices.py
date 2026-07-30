# backend/tts/voices.py

import json
import os
import logging

logger = logging.getLogger(__name__)

# Default voices if voices.json is missing
VOICE_REGISTRY = {
    "default_system": {
        "id": "default_system",
        "name": "Default (System)",
        "ref_audio_path": None,
        "prompt_text": None,
        "prompt_lang": None,
        "text_lang": None,
    }
}

def load_voices():
    """Loads the voice registry from voices.json if it exists."""
    global VOICE_REGISTRY
    json_path = os.path.join(os.path.dirname(__file__), "voices.json")
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                loaded_voices = json.load(f)
                VOICE_REGISTRY.update(loaded_voices)
        except Exception as e:
            logger.error(f"Failed to load voices.json: {e}")

# Load voices at module initialization
load_voices()

def get_available_voices():
    """Returns a list of available voices (ID and name only)."""
    return [{"id": v["id"], "name": v["name"]} for v in VOICE_REGISTRY.values()]

def get_voice(voice_id: str):
    """Returns the full voice configuration for a given voice ID."""
    return VOICE_REGISTRY.get(voice_id)
