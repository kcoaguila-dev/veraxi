# backend/tts/voices.py

VOICE_REGISTRY = {
    "default_system": {
        "id": "default_system",
        "name": "Default (System)",
        "ref_audio_path": None,
        "prompt_text": None,
        "prompt_lang": None,
        "text_lang": None,
    },
    "voice_1": {
        "id": "voice_1",
        "name": "Alex (English)",
        "ref_audio_path": "alex_ref.wav",
        "prompt_text": "This is a reference audio for Alex.",
        "prompt_lang": "en",
        "text_lang": "en",
    },
    "voice_2": {
        "id": "voice_2",
        "name": "Emma (English)",
        "ref_audio_path": "emma_ref.wav",
        "prompt_text": "This is a reference audio for Emma.",
        "prompt_lang": "en",
        "text_lang": "en",
    },
}

def get_available_voices():
    """Returns a list of available voices (ID and name only)."""
    return [{"id": v["id"], "name": v["name"]} for v in VOICE_REGISTRY.values()]

def get_voice(voice_id: str):
    """Returns the full voice configuration for a given voice ID."""
    return VOICE_REGISTRY.get(voice_id)
