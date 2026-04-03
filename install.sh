#!/bin/sh
set -eu

REPO="mwunsch/termscope"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Linux)  OS="linux" ;;
  Darwin) OS="macos" ;;
  *) echo "error: unsupported OS: $OS" >&2; exit 1 ;;
esac

# Detect arch
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="aarch64" ;;
  arm64)   ARCH="aarch64" ;;
  *) echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# Get latest version from GitHub API
if [ -n "${VERSION:-}" ]; then
  TAG="v$VERSION"
else
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)"
fi

if [ -z "$TAG" ]; then
  echo "error: could not determine latest version" >&2
  exit 1
fi

VERSION="${TAG#v}"
NAME="termscope-${VERSION}-${ARCH}-${OS}"
URL="https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading termscope $TAG for $OS/$ARCH..."
curl -fsSL "$URL" -o "$TMPDIR/$NAME.tar.gz"
tar xzf "$TMPDIR/$NAME.tar.gz" -C "$TMPDIR"

echo "Installing binary to $INSTALL_DIR..."
install -d "$INSTALL_DIR"
install -m 755 "$TMPDIR/$NAME/termscope" "$INSTALL_DIR/termscope"

MAN_BASE="${MAN_DIR:-$HOME/.local/share/man}"

echo "Installing man pages..."
for page in "$TMPDIR/$NAME"/man/*; do
  [ -f "$page" ] || continue
  section="${page##*.}"
  dest="$MAN_BASE/man$section"
  install -d "$dest"
  install -m 644 "$page" "$dest/$(basename "$page")"
  echo "  $(basename "$page") -> $dest/"
done

# Install agent skill if Claude Code is present
SKILL_DIR="$HOME/.claude/skills/termscope"
if [ -d "$HOME/.claude" ]; then
  echo "Installing agent skill..."
  install -d "$SKILL_DIR"
  install -m 644 "$TMPDIR/$NAME/SKILL.md" "$SKILL_DIR/SKILL.md"
  echo "  SKILL.md -> $SKILL_DIR/"
fi

echo ""
echo "Done! Installed termscope $TAG"
echo "  Binary:    $INSTALL_DIR/termscope"
echo "  Man pages: $MAN_BASE/"
[ -d "$SKILL_DIR" ] && echo "  Skill:     $SKILL_DIR/SKILL.md"
echo ""
echo "Run 'termscope --version' to verify."

# Check if INSTALL_DIR is in PATH
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "Note: $INSTALL_DIR is not in your PATH. Add it with:" >&2
     echo "  export PATH=\"$INSTALL_DIR:\$PATH\"" >&2 ;;
esac
