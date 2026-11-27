# Virt's sounds

All of Virt's sounds are free to use. Nothing here needs credit, but this is where each one came from.

| Files | Source | License |
|---|---|---|
| `virt-chime-*.caf` (the Chime style) | Synthesized for Virt by `scripts/sounds.py synth` | Virt's own |
| `virt-start-go.caf` (the green light: when a rest ends, in Chime and Digital) | Synthesized for Virt by `scripts/sounds.py start` | Virt's own |
| `virt-*-zero.caf` (the tone styles, Digital up to Quest jingle) | Synthesized for Virt from plain waves by `scripts/sounds.py tones` (no samples, nothing downloaded). The game-style ones (Arcade, Level up, Coin pickup, Victory, Bounce, Quest jingle) are original little tunes written here, not copies of any game's jingle; keep it that way | Virt's own |
| `virt-digital-*.caf` (the Digital style) | Picked, trimmed and leveled from Kenney's Interface Sounds (`scripts/sound-picks.json` names each file) by `.github/workflows/sounds.yml` | CC0 1.0 (public domain) |
| `virt-chime.wav` (the Classic style; in `App/`) | Virt's first chime | Virt's own |

Kenney's packs (Kenney Vleugels, kenney.nl), all CC0 1.0 Universal
(https://creativecommons.org/publicdomain/zero/1.0/):

- Interface Sounds: https://kenney.nl/assets/interface-sounds
- UI Audio: https://kenney.nl/assets/ui-audio
- Digital Audio: https://kenney.nl/assets/digital-audio

kenney.nl refuses automated downloads, so the workflow takes the packs from Kenney's own posts on OpenGameArt, which
carry the same CC0 license: Interface Sounds is https://opengameart.org/content/interface-sounds. UI Audio and Digital
Audio weren't found there under those names, so nothing is used from them. Interface Sounds has no bell, so the
standard Chime style is synthesized (the fallback), and the Kenney picks make the Digital style.

The packs themselves aren't kept in this repo, only the few files picked from them.
