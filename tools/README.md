
## check the client's audio, end to end

`measure_pitch.py` answers the one question no counter can: does the audio that
comes out of the speaker have the same pitch as the audio the host sent?

    # 1. a host that streams a known tone instead of the radio
    hamdeck-host --radio "" --audio tone:1000 --port 5902

    # 2. point a client at it, record what the sound device plays, then:
    tools/measure_pitch.py recorded.wav 1000

A client playing a 22050 Hz stream at 44100 passes every other check in this
repo - right packet count, right byte count, healthy level meter, full bar - and
sounds an octave high. This is the only check that sees it.

## check the client's audio, end to end

`measure_pitch.py` answers the one question no counter can: does the audio that
comes out of the speaker have the same pitch as the audio the host sent?

    # 1. a host that streams a known tone instead of the radio
    hamdeck-host --radio "" --audio tone:1000 --port 5902

    # 2. point a client at it, record what the sound device plays, then:
    tools/measure_pitch.py recorded.wav 1000

A client playing a 22050 Hz stream at 44100 passes every other check in this
repo - right packet count, right byte count, healthy level meter, full bar - and
sounds an octave high. This is the only check that sees it.
