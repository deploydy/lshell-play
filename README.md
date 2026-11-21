# lshell-play
Simple configuration for swayFX

# Preview
<img width="1920" height="1080" alt="изображение" src="https://github.com/user-attachments/assets/d74f0264-326a-46de-8964-0f2044b38de7" />
<img width="1920" height="1080" alt="изображение" src="https://github.com/user-attachments/assets/77810f13-9aad-4704-aef6-6ff3474da08a" />

# Wallpapers 
<img width="4029" height="2686" alt="alessandra-wolfsberger-RQAvuljojbw-unsplash" src="https://github.com/user-attachments/assets/c5ac70b8-2c04-4981-a7c5-5219a978ac18" />
<img width="4390" height="2927" alt="alessandra-wolfsberger-ZeHmY0wc_aY-unsplash" src="https://github.com/user-attachments/assets/97b01e7b-a85e-447f-a108-394e07800202" />

### Key Bindings

<details>
<summary>Click to view full keybindings list</summary>



| Keybind | Action | Command |
| :--- | :--- | :--- |
| **Applications** | | |
| `Mod` + `m` | Passwords Manager | `kitty python3 $HOME/.config/passwords.py` |
| `Mod` + `s` | Config Settings | `kitty python3 $HOME/.config/lshell.py` |
| `Mod` + `Enter` | Open Terminal | `$term (Kitty)` |
| `Mod` + `d` | App Launcher | `rofi -show drun` |
| `Mod` + `c` | Crypto Monitor | `kitty python3 $HOME/.config/cryptosee.py` |
| `Mod` + `b` | Browser | `firefox` |
| `Mod` + `n` | File Manager | `dolphin` |
| `Mod` + `w` | Wallpaper Manager | `waypaper` |
| `Mod` + `.` | Emoji Launcher | `rofi -show emoji` |
| `Mod` + `shift` + `e` | Logout Manager | `wlogout` |
| **Navigation & Workspaces** | | |
| `Mod` + `Tab` | Visual Window List | `rofi -show window` |
| **System** | | |
| `Mod` + `q` | Kill Focused Window | `kill` |
| `Mod` + `Shift` + `c` | Reload Configuration | `reload` |
| `Mod` + `Shift` + `e` | Exit Sway | `swaynag` |
| **Screenshots** | | |
| `Mod` + `Shift` + `s` | Region Screenshot | `grim + slurp` |
| **Window Management** | | |
| `Mod` + `Shift` + `Space` | Toggle Floating | `floating toggle` |
| `Mod` + `Shift` + `Minus` | Scratchpad (Move) | `move scratchpad` |
| **Hardware / Media** | | |
| `Vol Up/Down/Mute` | Audio Control | `pactl` |
| `Play/Next/Prev` | Media Control | `playerctl` |


</details>

# Install
## Arch Linux
```bash
cd ~
curl -O https://raw.githubusercontent.com/deploydy/lshell-play/main/install.sh
chmod +x install.sh
./install.sh
```

# System Requirements

* **OS:** Arch Linux (Arch-based)
* **GPU:** Intel, AMD, or Nvidia with native Wayland support
* **RAM:** 1 GB minimum (2 GB recommended)
* **CPU:** Any modern dual-core processor
* **Storage:** 16 GB or more for comfortable system use

# Once installed, do this
Press Win + S and select the panel position and your city. Press Enter and select item 0 and press Enter again, then reload the config - Win+Shift+C
