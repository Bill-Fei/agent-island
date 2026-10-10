"""Original 120 BPM composition. NumPy oscillators + seeded noise; no samples."""
import argparse
import json
import math
import wave
from pathlib import Path
import numpy as np

SR = 48000
LENGTH = 30
N = SR * LENGTH


def compose(destination):
    rng = np.random.default_rng(10092026)
    mix = np.zeros((N, 2), np.float64)

    def add(start, signal, gain=1, pan=0):
        start = int(round(start * SR))
        n = min(len(signal), N - start)
        if n <= 0 or start < 0:
            return
        gains = np.array([math.cos((pan + 1) * math.pi / 4),
                          math.sin((pan + 1) * math.pi / 4)])
        if signal.ndim == 1:
            mix[start:start+n] += signal[:n, None] * gains * gain
        else:
            mix[start:start+n] += signal[:n] * gain

    def times(seconds):
        return np.arange(int(SR * seconds)) / SR

    def note_freq(midi):
        return 440 * 2 ** ((midi - 69) / 12)

    def synth(midi, seconds, kind="pluck"):
        t = times(seconds)
        f = note_freq(midi)
        if kind == "bass":
            sig = np.sin(2*np.pi*f*t) + .26*np.sin(2*np.pi*f*2*t) + .12*np.sin(2*np.pi*f*3*t)
            env = (1-np.exp(-t*250))*np.exp(-t*8)
        elif kind == "pad":
            sig = (np.sin(2*np.pi*f*t) + .35*np.sin(2*np.pi*f*1.003*t) + .14*np.sin(2*np.pi*f*2*t))
            env = np.minimum(t/.12, 1)*np.minimum((seconds-t)/.35, 1)*.4
        else:
            sig = np.sin(2*np.pi*f*t + 2*np.sin(2*np.pi*f*2*t)*np.exp(-t*15)) + .23*np.sin(2*np.pi*f*3*t)
            env = (1-np.exp(-t*500))*np.exp(-t*7)
        return sig * env

    def kick(strength=1):
        t = times(.44)
        f = 46 + 130*np.exp(-t*35)
        phase = 2*np.pi*np.cumsum(f)/SR
        low = np.sin(phase)*np.exp(-t*11)
        click = rng.normal(0, 1, len(t))*np.exp(-t*500)*.18
        return np.tanh((low+click)*1.6)*strength

    def hat(seconds=.07):
        t = times(seconds)
        nz = rng.normal(0, 1, len(t))
        return (nz - np.roll(nz, 1)) * np.exp(-t*55) * .15

    def snare():
        t = times(.21)
        nz = rng.normal(0, 1, len(t))
        return .24*nz*np.exp(-t*25) + .14*np.sin(2*np.pi*181*t)*np.exp(-t*35)

    # D minor / Bb major / F / C: intentional tonal continuity across 13 bars.
    chords = [[50, 57, 62, 65, 69], [46, 53, 58, 62, 65],
              [41, 48, 57, 60, 65], [48, 55, 60, 64, 67]]
    bass = [38, 34, 29, 36]
    progression = [0, 0, 1, 1, 2, 2, 3, 3, 0, 1, 2, 3, 0]
    for bar in range(13):
        pos = bar * 2
        ci = progression[bar]
        for midi in chords[ci][2:]:
            add(pos, synth(midi, 2.15, "pad"), .085, (midi%3-1)*.55)
        for step in range(8):
            moment = pos + step * .25
            midi = chords[ci][2+(step%3)] + (12 if bar in (4, 7, 12) else 0)
            velocity = .10 + .035*(step%2==0)
            add(moment, synth(midi, .65), velocity, .55*math.sin(step*1.3+bar))
            if bar >= 2:
                add(moment, hat(), .32 if step%2 else .45, .3*math.sin(step*2))
        for beat in range(4):
            moment = pos + beat*.5
            add(moment, kick(), .36 if bar else .26)
            add(moment, synth(bass[ci] + (12 if beat==3 else 0), .44, "bass"), .26)
            if beat%2 and bar >= 2:
                add(moment, snare(), .31, -.12)
        # Every cut is a bar downbeat: short original stereo sweep + metallic tick.
        if bar:
            t = times(.24)
            f = 1900*np.exp(-t*10)+120
            sw = np.sin(2*np.pi*np.cumsum(f)/SR) * np.exp(-t*15)
            add(pos, sw, .12, (-1 if bar%2 else 1)*.6)
        if bar >= 8:
            t=times(.10)
            tick=np.sin(2*np.pi*2200*t)*np.sin(2*np.pi*1487*t)*np.exp(-t*75)
            add(pos+1.5,tick,.12,.6)

    # Product gesture sound design, all oscillators/noise generated locally.
    for position in (.12, .786667, 1.453333):
        t=times(.15)
        f=410*np.exp(-t*18)+75
        add(position, np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*32), .22)
    for position in (4,4.65,5.3,18,18.5,19,19.5,24,24.5,25):
        t=times(.32)
        sw=rng.normal(0,1,len(t))*np.sin(np.pi*t/.32)**2*np.exp(-t*7)
        add(position,sw,.025,math.sin(position))

    # Low-volume deterministic reverb / stereo ping-pong; no external IR.
    dry=mix.copy()
    for delay,gain in [(.125,.13),(.25,.11),(.375,.065),(.5,.05),(.75,.035)]:
        n=int(delay*SR)
        mix[n:]+=dry[:-n,::-1]*gain

    # Absolutely silent beat, including all preceding effect tails.
    mute_a,mute_b=int(25.5*SR),int(26*SR)
    n=int(.009*SR)
    mix[mute_a-n:mute_a]*=np.linspace(1,0,n)[:,None]
    mix[mute_a:mute_b]=0

    # Logo slam at exactly 26.000 seconds, then a restrained Dm(add9) resolution.
    add(26,kick(1.35),.60)
    t=times(1.8)
    hit=(np.sin(2*np.pi*(48*t+5*(1-np.exp(-t*14))))*np.exp(-t*3)
         + rng.normal(0,1,len(t))*np.exp(-t*18)*.24
         + np.sin(2*np.pi*96*t)*np.exp(-t*7)*.35)
    add(26,hit,.43)
    for midi in [50,57,62,65,69,76]:
        sig=synth(midi,3.9,"pad")
        add(26,sig,.14,(midi%3-1)*.5)
    t=times(.62)
    add(26.98,np.sin(2*np.pi*880*t)*np.exp(-t*10)+.4*np.sin(2*np.pi*1320*t)*np.exp(-t*15),.17)

    # End fade + gentle nonlinear bus saturation, -1 dBFS peak.
    mix[-int(.4*SR):]*=np.linspace(1,0,int(.4*SR))[:,None]
    mix=np.tanh(mix*1.1)
    mix*=10**(-1/20)/max(np.max(np.abs(mix)),1e-9)
    mix[mute_a:mute_b]=0
    pcm=np.round(mix*32767).astype('<i2')
    with wave.open(str(destination),"wb") as wav:
        wav.setnchannels(2);wav.setsampwidth(2);wav.setframerate(SR);wav.writeframes(pcm.tobytes())
    report={"title":"Quiet Power — original NumPy score", "bpm":120,"sample_rate":SR,
            "duration":30,"channels":2,"silence":[25.5,26],
            "silent_samples_max":int(np.max(np.abs(pcm[mute_a:mute_b]))),
            "peak_dbfs":round(20*np.log10(np.max(np.abs(mix))),3),
            "rms_dbfs":round(20*np.log10(np.sqrt(np.mean(mix**2))),3),
            "seed":10092026,"external_samples":0}
    destination.with_suffix('.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
    print(json.dumps(report,ensure_ascii=False))


if __name__ == "__main__":
    ap=argparse.ArgumentParser();ap.add_argument("output",type=Path);args=ap.parse_args()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    compose(args.output)
