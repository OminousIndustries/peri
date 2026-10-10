# Bring your own local AI stack

**Not implemented yet.** This is a starting point for adapting Peri with a coding agent to the LLM, speech recognition and text-to-speech services you already run at home. There is no local-backend switch or ready-made offline installer in this release.

The current software uses OpenAI Realtime for conversation and speech. A local text-generation endpoint alone cannot replace that whole connection: Peri also needs microphone transport, transcription, speech playback, turn detection and interruption handling.

## A practical starting design

Keep the Pi as the display, microphone and speaker device. Let a computer or server on your home network run the models:

```text
Peri microphone → local speech-to-text → local LLM → local text-to-speech → Peri speakers
                         ↕                  ↕                ↕
                     transcripts       conversation     speaking/finished
                         └──────────── Peri display ─────────┘
```

Running everything on the Pi 4B would need separate performance testing. For a first version, use one complete spoken turn at a time and tap-to-interrupt; add streaming or voice interruption once the basic path works.

## Give your coding agent these details

- **LLM:** server URL, API format, model name, authentication and whether it streams responses.
- **Speech-to-text:** endpoint, accepted audio format/sample rate, language and how it signals a completed transcript.
- **Text-to-speech:** endpoint, voice, output format/sample rate and whether it streams audio.
- **Host:** where each service runs and how the Pi reaches it over the home network.
- **Conversation:** how to detect the end of speech, maintain history, cancel a reply and handle unavailable services.

Use environment variables for any credentials. Decide explicitly whether local mode may ever fall back to a cloud service; for a local-only build, disable cloud fallback and verify that audio and requests stay on the intended hosts.

## Where to adapt the code

| Area | Starting files | Work needed |
|---|---|---|
| Audio connection | [realtime.js](../device/web/js/realtime.js), [audio.js](../device/web/js/audio.js) | Replace or adapt the WebRTC connection, microphone transport and returned audio playback |
| Conversation and display | [agent.js](../device/web/js/agent.js) | Map local transcripts and listening/thinking/speaking events; preserve tap, mute, sleep and cancellation |
| Server endpoints | [routes/api.py](../device/server/peri_server/routes/api.py), [openai_client.py](../device/server/peri_server/openai_client.py), [context.py](../device/server/peri_server/context.py) | Add a backend adapter for local services and remove the OpenAI-key requirement from that local path |
| Persona and session | [session.py](../device/server/peri_server/session.py), [catalog.py](../device/server/peri_server/catalog.py) | Reuse personality instructions and adapt conversation history/tool handling to the selected LLM |
| Configuration and controls | [config.py](../device/server/peri_server/config.py), [settings.py](../device/server/peri_server/settings.py), [constants.py](../device/server/peri_server/constants.py), [settings.js](../device/web/js/settings.js) | Add backend selection and service endpoints; replace cloud-specific model/voice choices in local mode |
| Diagnostics | [verify.sh](../device/scripts/verify.sh), [diag.js](../device/web/js/diag.js) | Check the selected local services instead of requiring OpenAI credentials/reachability |

`PERI_OPENAI_BASE_URL` exists, but the current client still calls Realtime endpoints and the interface expects Realtime events. Pointing it at an ordinary local chat-completions server is not a working local-AI implementation.

## A prompt to get started

Copy this into your coding agent, then provide your actual service details:

> Adapt this Peri repository to my home AI stack. Local AI is not currently implemented. First inspect docs/LOCAL_AI.md and the current browser/server audio flow, then ask for my LLM, speech-to-text and text-to-speech endpoint formats, model/voice names, authentication and sample rates. Add an explicit local backend while preserving the existing OpenAI option. Keep model inference on my chosen home server and the Pi as the audio/display device. Start with complete speech turns and tap-to-interrupt. Preserve tap-to-wake, microphone mute, sleep, captions, personality and listening/thinking/speaking display states. Make cancellation stop both generation and queued audio, and prevent stale replies after sleeping or reconnecting. Keep credentials on the server. Local mode must work without an OpenAI key and must not silently fall back to cloud services. Keep PERI_HEAD_DRIVER=none; the optional Arduino is independent. Add focused tests with mock services, document setup for my actual stack, and distinguish automated checks from physical microphone/speaker tests.

## What to verify on your build

Check a full microphone → transcript → reply → spoken-audio round trip, then test mute, sleep, interruption and a second conversation. Disconnect each local service to confirm understandable errors and recovery. Check for speaker feedback, delayed/stale audio, correct sample rates and acceptable latency on the real Pi. If you want offline operation, also test with the internet disconnected after installing the models and dependencies.
