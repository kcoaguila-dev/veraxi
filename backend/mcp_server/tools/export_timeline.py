import os
from typing import Any, Literal

import opentimelineio as otio


def build_otio(clips: list[dict[str, Any]]) -> otio.schema.Timeline:
    timeline = otio.schema.Timeline("Veraxi_Generated_Timeline")
    
    # We will create two tracks: one for Video (which might have text overlay markers or generic generators) and one for Audio
    video_track = otio.schema.Track("Video", kind=otio.schema.TrackKind.Video)
    audio_track = otio.schema.Track("Audio", kind=otio.schema.TrackKind.Audio)
    
    timeline.tracks.append(video_track)
    timeline.tracks.append(audio_track)
    
    for clip_data in clips:
        # Create a basic gap/generator for the video track to represent the scene length
        duration = otio.opentime.from_seconds(clip_data.get("duration", 2.0))
        
        # Audio clip
        audio_clip = otio.schema.Clip(
            name=f"{clip_data.get('character', 'Voice')} - {clip_data.get('dialogue', '')[:20]}...",
            media_reference=otio.schema.ExternalReference(
                target_url=clip_data.get("audio_path", ""),
                available_range=otio.opentime.TimeRange(
                    start_time=otio.opentime.from_seconds(0.0),
                    duration=duration
                )
            ),
            source_range=otio.opentime.TimeRange(
                start_time=otio.opentime.from_seconds(0.0),
                duration=duration
            )
        )
        audio_track.append(audio_clip)
        
        # Video clip (placeholder)
        video_clip = otio.schema.Clip(
            name=clip_data.get('character', 'Scene'),
            source_range=otio.opentime.TimeRange(
                start_time=otio.opentime.from_seconds(0.0),
                duration=duration
            )
        )
        
        # Add dialogue as a marker
        marker = otio.schema.Marker(
            name="Dialogue",
            marked_range=otio.opentime.TimeRange(
                start_time=otio.opentime.from_seconds(0.0),
                duration=duration
            ),
            color=otio.schema.MarkerColor.GREEN
        )
        # Store full dialogue in metadata
        marker.metadata.update({"dialogue": clip_data.get("dialogue", "")})
        video_clip.markers.append(marker)
        
        video_track.append(video_clip)
        
    return timeline

def build_fcpxml(clips: list[dict[str, Any]]) -> str:
    # A very simplified FCPXML generator for basic sequential audio clips
    xml = ['<?xml version="1.0" encoding="UTF-8"?>']
    xml.append('<!DOCTYPE fcpxml>')
    xml.append('<fcpxml version="1.9">')
    xml.append('  <resources>')
    xml.append('    <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>')
    for i, clip in enumerate(clips):
        path = clip.get("audio_path", f"file:///placeholder_{i}.wav")
        xml.append(f'    <asset id="a{i}" src="{path}" hasAudio="1" hasVideo="0"/>')
    xml.append('  </resources>')
    xml.append('  <library>')
    xml.append('    <event name="Veraxi Event">')
    xml.append('      <project name="Veraxi Timeline">')
    xml.append('        <sequence format="r1">')
    xml.append('          <spine>')
    
    total_time = 0.0
    for i, clip in enumerate(clips):
        duration = clip.get("duration", 2.0)
        # Convert seconds to fractional seconds string (e.g. "3000/1000s")
        dur_str = f"{int(duration*1000)}/1000s"
        start_str = f"{int(total_time*1000)}/1000s"
        
        xml.append(f'            <clip name="{clip.get("character", "Voice")}" duration="{dur_str}" offset="{start_str}">')
        xml.append(f'              <audio ref="a{i}" duration="{dur_str}" />')
        
        # Add a title/marker for dialogue
        dialogue = clip.get("dialogue", "").replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;')
        xml.append(f'              <title name="{clip.get("character", "Title")}" offset="0s" duration="{dur_str}">')
        xml.append(f'                <text><text-style>{dialogue}</text-style></text>')
        xml.append('              </title>')
        xml.append('            </clip>')
        
        total_time += duration
        
    xml.append('          </spine>')
    xml.append('        </sequence>')
    xml.append('      </project>')
    xml.append('    </event>')
    xml.append('  </library>')
    xml.append('</fcpxml>')
    
    return "\n".join(xml)

def build_ymm4_csv(clips: list[dict[str, Any]]) -> str:
    # Generates a CSV formatted for YMM4's CSV import feature.
    # Typical YMM4 CSV columns: キャラクター,セリフ,音声ファイルパス (Character, Dialogue, Audio Path)
    lines = []
    lines.append("キャラクター,セリフ,音声ファイルパス")
    
    for clip in clips:
        char = clip.get("character", "").replace('"', '""')
        dialogue = clip.get("dialogue", "").replace('"', '""').replace("\n", " ")
        path = clip.get("audio_path", "").replace('"', '""')
        
        lines.append(f'"{char}","{dialogue}","{path}"')
        
    return "\n".join(lines)


def mcp_veraxi_mcp_export_timeline(
    clips: list[dict[str, Any]], 
    format: Literal["otio", "fcpxml", "ymm4_csv"] = "otio",
    output_name: str = "veraxi_timeline"
) -> str:
        """
        Export a structured list of clips/dialogue into a universal video editing timeline format.
        This enables workflows for content creators (Premiere, Resolve, Yukkuri Movie Maker).
        
        Args:
            clips: A list of dicts. Each dict must contain:
                   - 'start_time' (float)
                   - 'duration' (float)
                   - 'character' (string, optional)
                   - 'dialogue' (string, optional)
                   - 'audio_path' (string, optional)
            format: "otio" (OpenTimelineIO, recommended), "fcpxml" (Final Cut Pro), or "ymm4_csv" (for YMM4 native import).
            output_name: Base filename (without extension).
            
        Returns:
            The absolute path to the generated timeline file.
        """
        
        workspace_dir = os.environ.get("VERAXI_WORKSPACE_DIR", "/tmp")
        
        if format == "otio":
            timeline = build_otio(clips)
            filepath = os.path.join(workspace_dir, f"{output_name}.otio")
            otio.adapters.write_to_file(timeline, filepath)
            
        elif format == "fcpxml":
            xml_content = build_fcpxml(clips)
            filepath = os.path.join(workspace_dir, f"{output_name}.fcpxml")
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(xml_content)
                
        elif format == "ymm4_csv":
            csv_content = build_ymm4_csv(clips)
            filepath = os.path.join(workspace_dir, f"{output_name}.csv")
            # Shift-JIS or UTF-8 with BOM is usually preferred for Japanese CSV software, but utf-8 is safest for Python
            with open(filepath, "w", encoding="utf-8-sig") as f:
                f.write(csv_content)
        else:
            raise ValueError(f"Unsupported timeline format: {format}")
            
        return filepath
