# suspend: deliberate no-op — the sandbox is shared by every workspace of this
# project, and a sibling may be awake. Orca tears down its own relay regardless.
cat > /dev/null
printf 'orca-sbx: suspend is a no-op for the shared project sandbox\n' >&2
exit 0
