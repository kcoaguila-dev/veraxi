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

def get_all_voices():
    """Returns the full list of voice configurations."""
    return list(VOICE_REGISTRY.values())

def get_voice(voice_id: str):
    """Returns the full voice configuration for a given voice ID."""
    return VOICE_REGISTRY.get(voice_id)

def save_voices(new_voices: list[dict]):
    """Updates the registry and saves to voices.json."""
    global VOICE_REGISTRY
    
    # Preserve default system voice if not provided
    default_system = VOICE_REGISTRY.get("default_system")
    
    VOICE_REGISTRY = {}
    if default_system:
        VOICE_REGISTRY["default_system"] = default_system

    for v in new_voices:
        if v.get("id") == "default_system":
            continue # Don't allow overwriting the default system voice through the list
        if not v.get("id"):
            v["id"] = v.get("name", "").lower().replace(" ", "_")
        VOICE_REGISTRY[v["id"]] = v

    json_path = os.path.join(os.path.dirname(__file__), "voices.json")
    # Ensure the directory exists (though __file__ directory should exist)
    os.makedirs(os.path.dirname(json_path), exist_ok=True)
    try:
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(VOICE_REGISTRY, f, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.error(f"Failed to save voices.json: {e}")
        raise

def add_voice(voice_id: str, name: str, ref_audio_path: str, prompt_text: str, prompt_lang: str = "en", text_lang: str = "en"):
    """Adds a single voice and saves the registry."""
    global VOICE_REGISTRY
    
    if voice_id == "default_system":
        return
        
    VOICE_REGISTRY[voice_id] = {
        "id": voice_id,
        "name": name,
        "ref_audio_path": ref_audio_path,
        "prompt_text": prompt_text,
        "prompt_lang": prompt_lang,
        "text_lang": text_lang,
    }
    
    json_path = os.path.join(os.path.dirname(__file__), "voices.json")
    try:
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(VOICE_REGISTRY, f, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.error(f"Failed to save voices.json after adding voice: {e}")
        raise
