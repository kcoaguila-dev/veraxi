import os
import time
import logging

logger = logging.getLogger(__name__)

def cleanup_audio_cache(cache_dir: str, max_files: int = 100, max_age_hours: int = 24):
    """
    Cleans up the TTS audio cache by removing files older than max_age_hours 
    and keeping only the most recent max_files to save disk space.
    """
    try:
        if not os.path.exists(cache_dir):
            return
        
        now = time.time()
        files = []
        for filename in os.listdir(cache_dir):
            if not filename.endswith(".wav"):
                continue
            filepath = os.path.join(cache_dir, filename)
            stat = os.stat(filepath)
            
            # Delete if older than max_age
            if now - stat.st_mtime > max_age_hours * 3600:
                os.remove(filepath)
                logger.debug(f"Deleted old cached audio: {filename}")
            else:
                files.append((filepath, stat.st_mtime))
                
        # If still more than max_files, delete oldest
        if len(files) > max_files:
            files.sort(key=lambda x: x[1])
            for filepath, _ in files[:-max_files]:
                os.remove(filepath)
                logger.debug(f"Deleted cached audio (capacity limit): {os.path.basename(filepath)}")
                
    except Exception as e:
        logger.error(f"Error cleaning up audio cache: {e}")
