"""Original 120 BPM groove score for the V4 film. NumPy oscillators + seeded noise; no samples.
Deep-house shape: four-on-the-floor, offbeat hats, syncopated bass, sidechained chord stabs,
filter sweeps. Two drops sit on picture beats: 8.0 s (island reveal) and 26.0 s (logo).
Every effect is placed on a visible on-screen event (see film.js timeline)."""
import argparse
import json
import math
import wave
from pathlib import Path
import numpy as np

SR = 48000
LENGTH = 30
N = SR * LENGTH
BAR, BEAT, STEP = 2.0, .5, .125
SWING = .018


def compose(destination):
    rng = np.random.default_rng(10102026)
    drums = np.zeros((N, 2))
    music = np.zeros((N, 2))
    fx = np.zeros((N, 2))
    kicks = []

    def add(bus, start, signal, gain=1, pan=0):
        start = int(round(start * SR))
        n = min(len(signal), N - start)
        if n <= 0 or start < 0:
            return
        gains = np.array([math.cos((pan + 1) * math.pi / 4),
                          math.sin((pan + 1) * math.pi / 4)])
        bus[start:start+n] += signal[:n, None] * gains * gain

    def times(seconds):
        return np.arange(int(SR * seconds)) / SR

    def hz(midi):
        return 440 * 2 ** ((midi - 69) / 12)

    def noise(n):
        return rng.normal(0, 1, n)

    def box(x, k):
        return np.convolve(x, np.ones(k)/k, "same")

    # ---------------- instruments ----------------
    def kick():
        t = times(.46)
        f = 47 + 115*np.exp(-t*30)
        body = np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*7.5)
        nz = noise(len(t))
        click = (nz-np.roll(nz, 1))*np.exp(-t*320)*.12 + np.sin(2*np.pi*1700*t)*np.exp(-t*260)*.12
        return np.tanh((body+click)*1.9)*.85

    def clap():
        t = times(.38)
        sig = np.zeros(len(t))
        for d in (0, .009, .019, .028):
            n0 = int(d*SR)
            tt = t[:len(t)-n0]
            sig[n0:] += noise(len(tt))*np.exp(-tt*170)
        sig += noise(len(t))*np.exp(-t*16)*.35
        return (box(sig, 3)-box(sig, 28))*.9

    def chat():
        t = times(.05)
        nz = noise(len(t))
        hp = nz-2*np.roll(nz, 1)+np.roll(nz, 2)
        return hp*np.exp(-t*110)*.16

    def ohat():
        t = times(.3)
        nz = noise(len(t))
        hp = nz-2*np.roll(nz, 1)+np.roll(nz, 2)
        return hp*np.exp(-t*13)*(1-np.exp(-t*900))*.11

    def shaker():
        t = times(.07)
        nz = noise(len(t))
        return (nz-np.roll(nz, 1))*np.sin(np.pi*t/.07)**2*.05

    def snare():
        t = times(.2)
        nz = noise(len(t))
        return (box(nz, 2)-box(nz, 20))*np.exp(-t*30)*.6 + np.sin(2*np.pi*190*t)*np.exp(-t*40)*.35

    def bass(midi, seconds):
        t = times(seconds+.03)
        f = hz(midi)
        sig = .9*np.sin(2*np.pi*f*t)
        for n in range(2, 11):
            sig += np.sin(2*np.pi*f*n*t)/n*np.exp(-t*(2+n*3))*1.1
        env = (1-np.exp(-t*600))*np.clip((seconds+.03-t)/.03, 0, 1)*np.exp(-t*2.2)
        return np.tanh(sig*env*1.4)

    def stab(notes, seconds=.22):
        t = times(seconds)
        sig = np.zeros(len(t))
        for m in notes:
            f = hz(m)
            for n in range(1, 7):
                for det in (-.004, .004):
                    sig += np.sin(2*np.pi*f*n*(1+det)*t)/n*np.exp(-t*(4+n*3))
        env = (1-np.exp(-t*800))*np.exp(-t*9)*np.clip((seconds-t)/.02, 0, 1)
        return sig*env/len(notes)

    def pad(midi, seconds):
        t = times(seconds)
        f = hz(midi)
        sig = np.sin(2*np.pi*f*t)+.22*np.sin(2*np.pi*f*1.003*t)+.08*np.sin(2*np.pi*f*2*t)
        return sig*np.minimum(t/.35, 1)*np.minimum((seconds-t)/.5, 1)*.35

    def pluck(midi, seconds=.6):
        t = times(seconds)
        f = hz(midi)
        sig = (np.sin(2*np.pi*f*t + .55*np.sin(2*np.pi*f*2*t)*np.exp(-t*22))
               + .13*np.sin(2*np.pi*f*3*t)*np.exp(-t*15)
               + .055*np.sin(2*np.pi*f*4.01*t)*np.exp(-t*23))
        return sig*(1-np.exp(-t*350))*np.exp(-t*8)

    def click(bright=1.0):
        t = times(.09)
        return (np.sin(2*np.pi*1250*bright*t)+.22*np.sin(2*np.pi*2400*bright*t))*np.exp(-t*95)

    def whoosh(seconds, rise=True):
        t = times(seconds)
        nz = box(noise(len(t)), 9)
        shape = np.sin(np.pi*np.clip(t/seconds, 0, 1))**2
        if rise:
            shape *= np.linspace(.4, 1, len(t))
        return nz*shape

    def glide(seconds, f0, f1):
        t = times(seconds)
        f = f0*(f1/f0)**(t/seconds)
        return np.sin(2*np.pi*np.cumsum(f)/SR)*np.sin(np.pi*t/seconds)**2

    def riser(seconds):
        t = times(seconds)
        p = t/seconds
        nz = noise(len(t))
        bright = nz-box(nz, 12)
        sig = (box(nz, 12)*(1-p)+bright*p*1.6)*p**2
        sig += .35*np.sin(2*np.pi*np.cumsum(220*8**p)/SR)*p**3
        return sig

    def boom():
        t = times(1.6)
        f = 40+38*np.exp(-t*9)
        return np.tanh(np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*2.4)*1.6)

    def crash(seconds=2.6):
        t = times(seconds)
        nz = noise(len(t))
        return (nz-np.roll(nz, 1))*np.exp(-t*2.1)*(1-np.exp(-t*400))*.28

    # ---------------- harmony ----------------
    # Bm9 / Gmaj9 / Dmaj9 / Aadd9 — moody minor loop, resolving to D at the logo.
    CH = [[47,54,59,62,66,73],[43,50,55,59,62,69],[50,57,62,66,69,76],[45,52,57,61,64,71]]
    ROOT = [35,31,38,33]
    # 15 bars of 2 s; bar 13/14 are the end card.
    PROG = [0,1,2,3,0,1,2,3,0,1,2,3,0,2,1]
    BASS_PAT = [(2,0,1.6),(3,12,.6),(6,0,1.6),(7,12,.6),(10,0,1.6),(11,0,.6),(13,12,.6),(14,7,1.4)]
    HOOK = [(0,5),(3,3),(6,4),(8,5),(11,2),(14,4)]

    def st(pos, s):
        return pos + s*STEP + (SWING if s % 2 else 0)

    def kick_at(t0, gain=1):
        add(drums, t0, kick(), .4*gain)
        kicks.append(t0)

    for bar in range(15):
        pos = bar*BAR
        ci = PROG[bar]
        chord, root = CH[ci], ROOT[ci]
        intro = bar == 0
        tense = bar in (1, 2)          # 2-6 s: the window-juggling problem
        build = bar == 3               # 6-8 s: push into the notch
        full = 4 <= bar <= 11 or bar == 13
        breakdown = bar == 12          # 24-25.5 s: focus, filtered down
        outro = bar == 14

        for m in chord[2:]:
            add(music, pos, pad(m, 2.25), .07, (m % 3-1)*.55)

        # kick
        if tense:
            for s in (0, 8, 11):
                kick_at(pos+s*STEP, .85)
        elif full or outro:
            for b in range(4):
                if outro and b == 3:
                    continue
                kick_at(pos+b*BEAT)
        # clap on 2 and 4
        if full or outro:
            for s in (4, 12):
                add(drums, st(pos, s), clap(), .3, -.08)
        elif tense:
            add(drums, st(pos, 12), clap(), .2, -.08)
        # hats
        if tense or full or breakdown or outro:
            for s in range(16):
                vel = [.55,.25,.85,.3][s % 4]
                if tense:
                    vel *= .8
                if breakdown:
                    vel *= .6
                add(drums, st(pos, s), chat(), vel, .35*math.sin(s*1.9+bar))
        if full or outro:
            for s in (2, 6, 10, 14):
                add(drums, st(pos, s), ohat(), .55, .22)
            for s in range(16):
                add(drums, st(pos, s)+.004, shaker(), .5 if s % 2 else .3, -.4)
        # bass
        if tense:
            for s in (0, 4, 8, 12):
                add(music, st(pos, s), bass(root, .09), .16)
        elif full or outro:
            for s, octv, ln in BASS_PAT:
                if outro and s > 10:
                    continue
                add(music, st(pos, s), bass(root+octv, ln*STEP), .22)
        elif breakdown:
            add(music, pos, bass(root, 1.2), .18)
        # chord stabs, sidechained with the music bus
        if full or outro or breakdown:
            for s, gv in ((3, .7), (6, .5), (11, .7)) + (((14, .5),) if bar % 2 else ()):
                add(music, st(pos, s), stab(chord[2:]), gv, .25*math.sin(s+bar))
        elif tense:
            add(music, st(pos, 3), stab(chord[2:]), .45, .2)
            add(music, st(pos, 11), stab(chord[2:]), .35, -.2)
        # glass hook — the motif that ties the film together
        if full or breakdown or tense:
            lift = 1.35 if 8 <= bar <= 11 else (.6 if tense else 1.0)
            for s, idx in HOOK:
                add(music, st(pos, s), pluck(chord[idx]+12 if idx < 3 else chord[idx]), .22*lift,
                    .45*math.sin(s*1.3+bar))

    # ---------------- picture-synced events ----------------
    # Intro: four glass notes, one per agent icon, riser into the laptop downbeat at 2.0.
    for t0, midi in zip([.55,.8,1.05,1.3], [71,74,78,83]):
        add(fx, t0, pluck(midi, .9), .2, (midi-77)/12)
    add(fx, 1.2, riser(.8), .05)
    add(fx, 2.0, boom(), .12)

    # S1: windows fly out of the dock, clicks, then everything minimises.
    for i in range(4):
        add(fx, 2.45+i*.15, whoosh(.35, False), .028, -.6+i*.4)
    for t0 in (3.5,4.0,4.5,5.0,5.5):
        add(fx, t0, click(), .07, -.15)
    for i in range(4):
        add(fx, 6.0+i*.07, glide(.28, 900, 380), .03, .2)

    # Build: snare roll accelerating into the 8.0 drop; glass bloom as the island wakes.
    roll = [6.0+i*.25 for i in range(6)] + [7.5+i*.0625 for i in range(7)]
    for i, t0 in enumerate(roll):
        add(drums, t0, snare(), .12+.22*i/len(roll), .1*math.sin(i))
    add(fx, 6.3, riser(1.62), .07)
    for i, m in enumerate([62,66,69,74,78]):
        add(fx, 7.4+i*.07, pluck(m, 1.2), .09, -.4+i*.2)
    # DROP
    add(fx, 8.0, crash(), 1.0, .1)
    add(fx, 8.0, boom(), .22)

    # Events: success arpeggio, attention chime, retract swish.
    for i, m in enumerate([74,78,81]):
        add(fx, 10.0+i*.08, pluck(m, .9), .14, .2)
    add(fx, 12.0, pluck(81, .8), .16, .25)
    add(fx, 12.16, pluck(76, 1.0), .14, .25)
    add(fx, 13.4, glide(.4, 700, 300), .04, -.2)

    # Hover dwell (0.2 s), panel opens with an impact; counters and rows tick in.
    add(fx, 14.6, click(1.6), .035)
    add(fx, 14.62, glide(.2, 500, 1400), .03)
    add(fx, 14.8, whoosh(.5, False), .05)
    add(fx, 14.8, boom(), .14)
    add(fx, 14.8, crash(1.6), .55, -.1)
    for i in range(6):
        add(fx, 15.3+i*.1, click(2.0), .018, .4*math.sin(i))

    # Open app: click, panel collapses, window returns; permission allowed.
    add(fx, 20.0, click(), .08)
    add(fx, 20.25, glide(.4, 1200, 400), .04)
    add(fx, 20.55, whoosh(.45, False), .03, -.3)
    add(fx, 22.4, click(), .08)
    for i, m in enumerate([78,81,86]):
        add(fx, 22.45+i*.07, pluck(m, .9), .13, .3)
    add(fx, 23.0, glide(.28, 900, 380), .03, .2)
    for k in range(60):
        t0 = 23.6 + k/40
        if t0 < 25.4:
            add(fx, t0, click(2.6), .006, .3*math.sin(k*1.7))
    # Push into the island: rising air + reversed crash land on the silent beat at 25.75.
    add(fx, 24.95, whoosh(.8), .06, .1)
    add(fx, 25.05, glide(.7, 300, 1100), .025)
    rc = crash(1.0)[::-1]
    add(fx, 25.75-len(rc)/SR, rc, .3)

    # Logo downbeat (second drop).
    add(fx, 26.0, boom(), .3)
    add(fx, 26.0, crash(3.0), 1.1)
    for m in [50,57,62,66,69,76]:
        add(fx, 26, pad(m, 3.9), .12, (m % 3-1)*.5)
    t = times(.62)
    add(fx, 26.98, np.sin(2*np.pi*880*t)*np.exp(-t*10)+.4*np.sin(2*np.pi*1320*t)*np.exp(-t*15), .14)

    # Build-up gap: everything but the bloom drops out for 80 ms before 8.0.
    for bus in (drums, music):
        a, b = int(7.92*SR), int(8.0*SR)
        bus[a:b] *= np.linspace(1, 0, b-a)[:, None]**3

    # ---------------- processing ----------------
    def lowpass(bus, keys):
        kt, kf = zip(*keys)
        fc = np.exp(np.interp(np.arange(N)/SR, kt, np.log(kf)))
        coef = (1-np.exp(-2*np.pi*fc/SR)).tolist()
        for ch in range(2):
            x = bus[:, ch].tolist()
            y1 = y2 = 0.0
            for i in range(N):
                a = coef[i]
                y1 += a*(x[i]-y1)
                y2 += a*(y1-y2)
                x[i] = y2
            bus[:, ch] = x

    lowpass(music, [(0,450),(1.7,900),(2.0,2200),(6.0,2200),(6.3,1100),(7.95,16000),
                    (24.3,16000),(25.7,380),(25.99,380),(26.0,16000),(28.2,16000),(29.9,600)])
    lowpass(drums, [(0,18000),(24.3,18000),(25.7,1400),(25.99,1400),(26.0,18000),(28.4,18000),(29.9,900)])

    # Sidechain: music bus ducks under each kick — the pump.
    duck = np.ones(N)
    tt = np.arange(int(.45*SR))/SR
    shape = 1-.62*np.exp(-tt/.1)*(1-np.exp(-tt/.003))
    for k in kicks:
        a = int(k*SR)
        n = min(len(shape), N-a)
        duck[a:a+n] = np.minimum(duck[a:a+n], shape[:n])
    music *= duck[:, None]

    mix = drums + music + fx
    # Deterministic ping-pong space on music + fx only (kick stays dry and tight).
    wet = music + fx
    for delay, gain in [(.1875,.12),(.375,.09),(.5625,.06),(.75,.04)]:
        n = int(delay*SR)
        mix[n:] += wet[:-n, ::-1]*gain

    mute_a, mute_b = int(25.75*SR), int(26*SR)
    n = int(.009*SR)
    mix[mute_a-n:mute_a] *= np.linspace(1, 0, n)[:, None]
    mix[mute_a:mute_b] = 0

    mix[-int(.6*SR):] *= np.linspace(1, 0, int(.6*SR))[:, None]
    mix = np.tanh(mix*1.5)
    mix *= 10**(-1/20)/max(np.max(np.abs(mix)), 1e-9)
    mix[mute_a:mute_b] = 0
    pcm = np.round(mix*32767).astype('<i2')
    with wave.open(str(destination), "wb") as wav:
        wav.setnchannels(2); wav.setsampwidth(2); wav.setframerate(SR); wav.writeframes(pcm.tobytes())
    report = {"title": "Agent 灵动岛 V4 — original NumPy groove score", "bpm": 120, "sample_rate": SR,
              "duration": 30, "channels": 2, "drops": [8.0, 26.0], "silence": [25.75, 26],
              "silent_samples_max": int(np.max(np.abs(pcm[mute_a:mute_b]))),
              "peak_dbfs": round(20*np.log10(np.max(np.abs(mix))), 3),
              "rms_dbfs": round(20*np.log10(np.sqrt(np.mean(mix**2))), 3),
              "seed": 10102026, "external_samples": 0}
    destination.with_suffix('.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("output", type=Path); args = ap.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    compose(args.output)
