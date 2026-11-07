"""Reproducible moving video, tone markers and a positive source PTS."""
from pathlib import Path
import os
import shutil
import subprocess

ROOT=Path(__file__).resolve().parent
FFMPEG=os.environ.get('FFMPEG') or shutil.which('ffmpeg')
if not FFMPEG:
    raise SystemExit('Set FFMPEG to an installed executable')
for name,color,hz in [('export-red',(255,0,0),440),('export-blue',(0,0,255),880)]:
    frames=bytearray()
    for k in range(90):
        image=bytearray(bytes(color)*(64*96))
        # Every frame differs; the white marker stays outside sampled color areas.
        for y in range(12):
            for x in range(k%56,k%56+8):
                offset=(y*64+x)*3;image[offset:offset+3]=b'\xff\xff\xff'
        frames.extend(image)
    subprocess.run([FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y',
        '-f','rawvideo','-pixel_format','rgb24','-video_size','64x96','-framerate','30','-i','pipe:0',
        '-f','lavfi','-i',f'sine=frequency={hz}:sample_rate=48000:duration=3',
        '-c:v','libx264','-threads','2','-pix_fmt','yuv420p','-g','30','-bf','0',
        '-c:a','aac','-b:a','128k','-ac','2','-movflags','+faststart','-shortest',str(ROOT/(name+'.mp4'))],input=bytes(frames),check=True)
subprocess.run([FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-y',
    '-itsoffset','0.12','-i',str(ROOT/'export-blue.mp4'),'-c','copy','-copyts',
    '-avoid_negative_ts','disabled',str(ROOT/'export-blue-delayed.mp4')],check=True)
