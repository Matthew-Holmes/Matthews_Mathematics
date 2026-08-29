#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Decide which TeX engine each source file needs.
#
# pdfLaTeX cannot typeset scripts outside its 8-bit font encodings (Chinese,
# Japanese, Korean, Arabic, Hebrew, Devanagari, Thai, ...). Those documents need
# a Unicode engine -- XeLaTeX or LuaLaTeX.
#
# Usage: 005_classifyCompileEngine.sh <latexFilesToCompile.txt> [latex_root]
# Emits NDJSON on stdout, one object per line:
#   {"path": "...", "engine": "pdflatex|xelatex|lualatex", "reason": "..."}
# -----------------------------------------------------------------------------
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <latexFilesToCompile.txt> [latex_root]" >&2
  exit 1
fi

COMPILE_LIST="$1"
LATEX_ROOT="${2:-latex}"

# -----------------------------------------------------------------------------
# Optional debug flag
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

START_SECONDS=$SECONDS

trap '
  ELAPSED=$(( SECONDS - START_SECONDS ))
  debug "Script completed in ${ELAPSED}s"
' EXIT

debug "Compile list: $COMPILE_LIST"
debug "LaTeX root:   $LATEX_ROOT"

# -----------------------------------------------------------------------------
# Per-file classifier, printing "<engine><TAB><reason>".
#
# Precedence:
#   1. An explicit "% !TeX program = ..." magic comment always wins. This is the
#      escape hatch for anything the heuristics below get wrong.
#   2. Packages that only work under a particular engine.
#   3. Characters from a script pdfLaTeX cannot render.
#   4. Otherwise pdfLaTeX.
# -----------------------------------------------------------------------------
read -r -d '' CLASSIFY_PL <<'PERL_EOF' || true
use strict;
use warnings;

sub verdict {
  my ($engine, $reason) = @_;
  print "$engine\t$reason";
  exit 0;
}

my $path = $ARGV[0];
open(my $fh, '<:raw', $path) or die "cannot read $path: $!\n";
my $raw = do { local $/; <$fh> };
close($fh);

# ---------------------------------------------------------------------------
# 1) Magic comment. Read from the RAW text, because it lives in a comment and
#    would be removed by the comment stripping below. TeXShop, TeXstudio and
#    VS Code LaTeX Workshop understand the same directive, so a file marked this
#    way builds the same way locally and in CI.
#      % !TeX program = xelatex
#      %!TEX TS-program = lualatex
# ---------------------------------------------------------------------------
my $head = substr($raw, 0, 4096);
if ($head =~ /^[ \t]*%+[ \t]*!\s*TE?X\s+(?:TS-)?program\s*=\s*([A-Za-z]+)/mi) {
  my $engine = lc($1);
  $engine = 'pdflatex' if $engine eq 'pdftex';
  $engine = 'xelatex'  if $engine eq 'xetex';
  $engine = 'lualatex' if $engine eq 'luatex';
  if ($engine =~ /^(?:pdflatex|xelatex|lualatex)$/) {
    verdict($engine, "magic comment: % !TeX program = $engine");
  }
}

my $src = $raw;
utf8::decode($src);  # best effort; malformed bytes are left as-is and ignored below

# ---------------------------------------------------------------------------
# Strip LaTeX comments, so decorative box-drawing rules, notes-to-self and
# commented-out scratch work never influence the decision. Matching "\\." first
# keeps an escaped \% and stops a literal \\ from swallowing the next character.
#
# Caveat: % inside verbatim/listings is stripped too. That only affects this
# heuristic, never the real compile, so it is not worth parsing properly.
# ---------------------------------------------------------------------------
$src =~ s/(\\.)|%.*/defined $1 ? $1 : ''/ge;

# ---------------------------------------------------------------------------
# 2) Engine-specific packages and classes.
# ---------------------------------------------------------------------------
my @loaded;
while ($src =~ /\\(?:usepackage|RequirePackage|documentclass)\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/g) {
  push @loaded, grep { length } map { my $p = $_; $p =~ s/^\s+|\s+$//g; $p } split(/,/, $1);
}

# LuaTeX-only: these drive the embedded Lua interpreter and cannot run under XeTeX.
my %lua_only = map { $_ => 1 } qw(
  luatexja luatexja-fontspec luatexja-preset luatexja-ruby
  luacode luaotfload luamplib luatexbase lua-ul luacolor
);

# Need a Unicode engine. fontspec and friends work under both XeTeX and LuaTeX;
# XeLaTeX is the default of the two because it is faster.
my %unicode_engine = map { $_ => 1 } qw(
  fontspec unicode-math polyglossia mathspec realscripts xltxtra xunicode
  xeCJK xeCJKfntef zxjatype
  ctex ctexart ctexrep ctexbook ctexbeamer
  bidi xepersian arabxetex
);

for my $pkg (@loaded) {
  verdict('lualatex', "loads LuaTeX-only package: $pkg") if $lua_only{$pkg};
}
for my $pkg (@loaded) {
  verdict('xelatex', "loads Unicode-engine package: $pkg") if $unicode_engine{$pkg};
}

# ---------------------------------------------------------------------------
# 3) Scripts pdfLaTeX cannot typeset out of the box.
#
# Each entry is [low, high, script name]. Add a range here if a new language
# starts appearing in the sources.
# ---------------------------------------------------------------------------
my @scripts = (
  [0x0370, 0x03FF, 'Greek'],
  [0x0400, 0x052F, 'Cyrillic'],
  [0x0530, 0x058F, 'Armenian'],
  [0x0590, 0x05FF, 'Hebrew'],
  [0x0600, 0x06FF, 'Arabic'],
  [0x0700, 0x074F, 'Syriac'],
  [0x0750, 0x077F, 'Arabic Supplement'],
  [0x0780, 0x07BF, 'Thaana'],
  [0x07C0, 0x07FF, 'NKo'],
  [0x0800, 0x08FF, 'Samaritan / Arabic Extended-A'],
  [0x0900, 0x097F, 'Devanagari'],
  [0x0980, 0x09FF, 'Bengali'],
  [0x0A00, 0x0A7F, 'Gurmukhi'],
  [0x0A80, 0x0AFF, 'Gujarati'],
  [0x0B00, 0x0B7F, 'Oriya'],
  [0x0B80, 0x0BFF, 'Tamil'],
  [0x0C00, 0x0C7F, 'Telugu'],
  [0x0C80, 0x0CFF, 'Kannada'],
  [0x0D00, 0x0D7F, 'Malayalam'],
  [0x0D80, 0x0DFF, 'Sinhala'],
  [0x0E00, 0x0E7F, 'Thai'],
  [0x0E80, 0x0EFF, 'Lao'],
  [0x0F00, 0x0FFF, 'Tibetan'],
  [0x1000, 0x109F, 'Myanmar'],
  [0x10A0, 0x10FF, 'Georgian'],
  [0x1100, 0x11FF, 'Hangul Jamo'],
  [0x1200, 0x139F, 'Ethiopic'],
  [0x13A0, 0x13FF, 'Cherokee'],
  [0x1780, 0x17FF, 'Khmer'],
  [0x1800, 0x18AF, 'Mongolian'],
  [0x1F00, 0x1FFF, 'Greek Extended'],
  [0x2E80, 0x2FFF, 'CJK radicals'],
  [0x3000, 0x303F, 'CJK punctuation'],
  [0x3040, 0x30FF, 'Japanese kana'],
  [0x3100, 0x312F, 'Bopomofo'],
  [0x3130, 0x318F, 'Hangul compatibility jamo'],
  [0x31C0, 0x31EF, 'CJK strokes'],
  [0x3200, 0x4DBF, 'CJK Extension A / enclosed CJK'],
  [0x4E00, 0x9FFF, 'Chinese (CJK Unified Ideographs)'],
  [0xA000, 0xA4CF, 'Yi'],
  [0xA960, 0xA97F, 'Hangul Jamo Extended-A'],
  [0xAC00, 0xD7FF, 'Korean (Hangul syllables)'],
  [0xF900, 0xFAFF, 'CJK compatibility ideographs'],
  [0xFB1D, 0xFB4F, 'Hebrew presentation forms'],
  [0xFB50, 0xFDFF, 'Arabic presentation forms-A'],
  [0xFE30, 0xFE4F, 'CJK compatibility forms'],
  [0xFE70, 0xFEFF, 'Arabic presentation forms-B'],
  [0xFF00, 0xFFEF, 'Halfwidth and fullwidth forms'],
  [0x10000, 0x10FFFF, 'astral plane (emoji, CJK extensions, historic scripts)'],
);

my $line_no = 0;
for my $line (split(/\n/, $src, -1)) {
  $line_no++;
  for my $ch (split(//, $line)) {
    my $cp = ord($ch);
    next if $cp < 0x0370;  # ASCII, Latin-1/Extended and IPA are fine under pdfLaTeX
    for my $range (@scripts) {
      if ($cp >= $range->[0] && $cp <= $range->[1]) {
        verdict('xelatex', sprintf('%s character U+%04X at line %d', $range->[2], $cp, $line_no));
      }
    }
  }
}

verdict('pdflatex', 'no Unicode-only scripts or packages detected');
PERL_EOF

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
FILE_COUNT=0

while IFS= read -r REL_PATH || [[ -n "$REL_PATH" ]]; do
  [[ -z "$REL_PATH" ]] && continue

  FULL_PATH="$LATEX_ROOT/$REL_PATH"

  if [[ ! -f "$FULL_PATH" ]]; then
    echo "Error: listed source file does not exist: $FULL_PATH" >&2
    exit 1
  fi

  # don't use ((...++)) here since can give exit code 1 in some bash versions
  let "FILE_COUNT+=1"

  RESULT="$(perl -e "$CLASSIFY_PL" "$FULL_PATH")"
  ENGINE="${RESULT%%$'\t'*}"
  REASON="${RESULT#*$'\t'}"

  debug "$REL_PATH -> $ENGINE ($REASON)"

  jq -cn \
    --arg path "$REL_PATH" \
    --arg engine "$ENGINE" \
    --arg reason "$REASON" \
    '{path: $path, engine: $engine, reason: $reason}'

done < "$COMPILE_LIST"

debug "Classified $FILE_COUNT source files"
