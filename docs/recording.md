# Recording the demo

Assets this recipe produces: a ≤30s GIF for the README hero and a ~75s
narrated video for social (LinkedIn native upload — better reach than a
link). Record the real room; nothing here is staged beyond choosing what
to show when.

## Shot list (~75s)

| Time | Shot | On screen |
|---|---|---|
| 0–8s | Cold open | The full 5-pane room, all panes alive |
| 8–20s | `bin/orc up` | Fresh terminal → room builds itself |
| 20–35s | A dispatch | Orchestra assigns a ticket; builder pane wakes; `cat` the `.msg` and its `.ack` receipt |
| 35–50s | The review | The PR page: reviewer APPROVE **with its probe list** visible — hold on this, it's the differentiator |
| 50–62s | The guard | `rm -rf` typed in an agent pane → blocked by the PreToolUse guard |
| 62–75s | Close | Merged PR + auto-closed issue; watch header all-idle; repo URL |

## Voiceover script (ElevenLabs-ready, ~170 words ≈ 75s)

> This is an AI engineering team. It lives in a tmux session on my laptop.
>
> One command builds the room: an orchestrator that plans and merges, a
> builder that writes test-first code, a reviewer from a different model
> family, and watchdogs keeping everyone honest.
>
> Work moves through a file-based inbox. Every dispatch is a message on
> disk — and every message gets an acknowledgment receipt. Nothing hides
> in a prompt.
>
> Every pull request is reviewed adversarially by a Gemini agent, and an
> approval only counts if it comes with the list of probes it actually
> ran. Claims get verified against artifacts, because we learned the hard
> way that agents will say "tested" when they haven't.
>
> And agents have rules here. Dangerous commands are blocked by guards
> the agents can't edit — the guard files are OS-immutable.
>
> Plan. Build. Review. Merge. With a human holding the gates.
>
> It's open source — link below.

Tip: generate at stability ~0.5 / similarity ~0.75, then nudge pacing by
adding paragraph breaks rather than SSML.

## Capture

- **Social video**: FocuSee (auto-zoom on the active pane works well for
  dense tmux layouts) or macOS ⌘⇧5. 1080p minimum; keep the terminal
  font ≥ 14pt — phone viewers.
- **README GIF**: `brew install vhs`, script the demo as a `.tape` so it
  replays identically, render, then trim to the 0–35s shots. Keep it
  under ~10 MB or GitHub will lag; link the full video from the README
  instead of embedding it.
- Drop the finished GIF at `docs/demo.gif` — the README already carries
  the placeholder comment pointing here.
