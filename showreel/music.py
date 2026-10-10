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
    rng = np.random.default_rng(10102026)
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
            sig = np.sin(2*np.pi*f*t) + .12*np.sin(2*np.pi*f*2*t)
            env = (1-np.exp(-t*180))*np.exp(-t*12)
        elif kind == "pad":
            sig = (np.sin(2*np.pi*f*t) + .22*np.sin(2*np.pi*f*1.002*t) + .08*np.sin(2*np.pi*f*2*t))
            env = np.minimum(t/.22, 1)*np.minimum((seconds-t)/.45, 1)*.35
        else:
            # Warm glass / marimba: gentle FM attack, rounded body, bell shimmer.
            sig = (np.sin(2*np.pi*f*t + .55*np.sin(2*np.pi*f*2*t)*np.exp(-t*22))
                   + .13*np.sin(2*np.pi*f*3*t)*np.exp(-t*15)
                   + .055*np.sin(2*np.pi*f*4.01*t)*np.exp(-t*23))
            env = (1-np.exp(-t*350))*np.exp(-t*8)
        return sig * env

    def kick(strength=1):
        t = times(.44)
        f = 54 + 66*np.exp(-t*40)
        phase = 2*np.pi*np.cumsum(f)/SR
        low = np.sin(phase)*np.exp(-t*11)
        click = rng.normal(0, 1, len(t))*np.exp(-t*500)*.06
        return np.tanh((low+click)*1.2)*strength

    def hat(seconds=.07):
        t = times(seconds)
        nz = rng.normal(0, 1, len(t))
        return (nz - np.roll(nz, 1)) * np.exp(-t*75) * .055

    def snare():
        t = times(.21)
        nz = rng.normal(0, 1, len(t))
        # Soft rim click rather than heavy snare.
        return .045*nz*np.exp(-t*90) + .10*np.sin(2*np.pi*920*t)*np.exp(-t*110)

    # Dmaj9 / Bm7 / Gmaj9 / A6. Bright, buoyant, light-footed original theme.
    chords = [[50,57,62,66,69,76],[47,54,59,62,66,69],
              [43,50,55,59,62,69],[45,52,57,61,64,66]]
    bass = [38,35,31,33]
    progression = [0,0,1,2,0,3,1,2,3,0,2,3,0]
    melody=[74,78,81,78,76,74,69,73,74,78,76,81,78]
    for bar in range(13):
        pos = bar * 2
        ci = progression[bar]
        for midi in chords[ci][2:]:
            add(pos, synth(midi, 2.15, "pad"), .055, (midi%3-1)*.55)
        for step in range(8):
            moment = pos + step*.25 + (.022 if step%2 else 0)
            midi = chords[ci][2+[0,2,1,3,2,1,3,1][step]]
            velocity = .13 if step in (0,3,6) else .075
            add(moment, synth(midi, .65), velocity, .45*math.sin(step*1.3+bar))
            if bar >= 2:
                add(moment, hat(), .26 if step%2 else .34, .3*math.sin(step*2))
        for offset,note,gain in [(0,melody[bar],.18),(.75,melody[bar]-2,.12),(1.25,melody[bar]+2,.14)]:
            add(pos+offset,synth(note,.72),gain,.2*math.sin(bar))
        for beat in range(4):
            moment = pos + beat*.5
            if beat in (0,2):add(moment, kick(), .24 if bar else .18)
            add(moment+(0 if beat%2==0 else .125), synth(bass[ci]+(12 if beat==3 else 0), .32, "bass"), .18)
            if beat%2 and bar >= 2:
                add(moment, snare(), .44, -.12)
        # Every cut is a bar downbeat: short original stereo sweep + metallic tick.
        if bar:
            t = times(.24)
            f = 1050*np.exp(-t*14)+390
            sw = np.sin(2*np.pi*np.cumsum(f)/SR) * np.exp(-t*24)
            add(pos, sw, .045, (-1 if bar%2 else 1)*.6)
        if bar >= 8:
            t=times(.10)
            tick=np.sin(2*np.pi*2200*t)*np.sin(2*np.pi*1487*t)*np.exp(-t*75)
            add(pos+1.5,tick,.035,.6)

    # Product gesture sound design, all oscillators/noise generated locally.
    for position in (.5, 1.166667, 1.833333):
        t=times(.15)
        f=410*np.exp(-t*18)+75
        add(position, np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*32), .12)
    for position in (4,4.5,5,18.2,24,24.5,25):
        t=times(.32)
        sw=rng.normal(0,1,len(t))*np.sin(np.pi*t/.32)**2*np.exp(-t*7)
        add(position,sw,.025,math.sin(position))

    # Soft tactile taps align with the illustrative controls, not live actions.
    for position in (6.75,17,23):
        t=times(.09)
        click=(np.sin(2*np.pi*1250*t)+.22*np.sin(2*np.pi*2400*t))*np.exp(-t*95)
        add(position,click,.065,-.15)
    for position in (5,16.5,18.2,22.5):
        t=times(.22);f=720+480*np.sin(np.pi*t/.44)
        glide=np.sin(2*np.pi*np.cumsum(f)/SR)*np.sin(np.pi*t/.22)**2*np.exp(-t*12)
        add(position,glide,.055,.25)

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

    # One weighty logo downbeat; bright Dmaj9 resolution and falling glass note.
    add(26,kick(1.35),.32)
    t=times(1.8)
    hit=(np.sin(2*np.pi*(48*t+5*(1-np.exp(-t*14))))*np.exp(-t*3)
         + rng.normal(0,1,len(t))*np.exp(-t*18)*.24
         + np.sin(2*np.pi*96*t)*np.exp(-t*7)*.35)
    add(26,hit,.12)
    for midi in [50,57,62,66,69,76]:
        sig=synth(midi,3.9,"pad")
        add(26,sig,.14,(midi%3-1)*.5)
    t=times(.62)
    add(26.98,np.sin(2*np.pi*880*t)*np.exp(-t*10)+.4*np.sin(2*np.pi*1320*t)*np.exp(-t*15),.17)

    # End fade + gentle nonlinear bus saturation, -1 dBFS peak.
    mix[-int(.4*SR):]*=np.linspace(1,0,int(.4*SR))[:,None]
    mix=np.tanh(mix*1.6)
    mix*=10**(-1/20)/max(np.max(np.abs(mix)),1e-9)
    mix[mute_a:mute_b]=0
    pcm=np.round(mix*32767).astype('<i2')
    with wave.open(str(destination),"wb") as wav:
        wav.setnchannels(2);wav.setsampwidth(2);wav.setframerate(SR);wav.writeframes(pcm.tobytes())
    report={"title":"Light Motion — original NumPy score V3", "bpm":120,"sample_rate":SR,
            "duration":30,"channels":2,"silence":[25.5,26],
            "silent_samples_max":int(np.max(np.abs(pcm[mute_a:mute_b]))),
            "peak_dbfs":round(20*np.log10(np.max(np.abs(mix))),3),
            "rms_dbfs":round(20*np.log10(np.sqrt(np.mean(mix**2))),3),
            "seed":10102026,"external_samples":0,"style":"D major / glass-marimba / lightly swung syncopation / rounded bass"}
    destination.with_suffix('.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
    print(json.dumps(report,ensure_ascii=False))


if __name__ == "__main__":
    ap=argparse.ArgumentParser();ap.add_argument("output",type=Path);args=ap.parse_args()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    compose(args.output)
