## Metal Max HD-2D Prototype

A HD-2D style RPG prototype inspired by Metal Max Returns, built with Godot 4.7.

### Concept
- **World**: Post-apocalyptic wasteland, same tone as Metal Max series
- **Visual style**: HD-2D (pixel-art sprites in 3D environments, Octopath Traveler style)
- **Core systems**: Turn-based combat, tank customization, bounty hunting, open-world exploration
- **Assets**: AI-generated pixel art and textures

### Project Structure
```
├── project.godot          # Godot project config
├── assets/                # AI-generated sprites, tiles, UI, audio
│   ├── sprites/           # Character & enemy pixel art
│   ├── tiles/             # Map tile textures
│   ├── ui/                # UI elements & icons
│   └── audio/             # BGM & SFX
├── data/                  # JSON data tables (enemies, equipment, etc.)
├── scenes/                # Godot scene files (.tscn)
├── scripts/               # GDScript files
│   ├── global/            # Autoload singletons (GameState, DataLoader)
│   ├── player/            # Player movement & camera
│   ├── world/             # World/map logic
│   ├── battle/            # Turn-based battle system
│   ├── tank/              # Tank customization system
│   └── ui/                # Dialogue, menus, HUD
└── shaders/               # Custom shaders (HD-2D post-processing)
```

### How to Run
1. Install [Godot 4.7](https://godotengine.org/download/)
2. Open this project folder in Godot
3. Press F5 to run

### Controls
| Action | Key |
|--------|-----|
| Move | WASD / Arrow Keys |
| Confirm | Z / Enter |
| Cancel | X / Esc |
| Interact | E / J |
| Menu | Esc |

### Current Status: Vertical Slice Prototype
- [x] HD-2D rendering pipeline (3D world + pixel sprites + DOF + Bloom)
- [x] Player 4-directional movement
- [x] Turn-based battle system
- [x] Tank customization system
- [x] Dialogue & menu UI
- [x] Data-driven design (JSON configs)
- [ ] Multiple maps & world map
- [ ] Full enemy roster
- [ ] Story & quests
- [ ] Audio integration
