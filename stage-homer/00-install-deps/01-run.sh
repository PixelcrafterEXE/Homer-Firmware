#!/bin/bash -e

PYPROJECT="${BASE_DIR}/../Software/pyproject.toml"

# Write requirements to /root/ (not /tmp/ – on_chroot mounts tmpfs over /tmp).
REQS_FILE="${ROOTFS_DIR}/root/homer_requirements.txt"

# Parse [project].dependencies from pyproject.toml, skipping the local
# self-referential entries that pip freeze adds ('homerpi', 'software').
python3 -c "
import re
with open('${PYPROJECT}') as f:
    text = f.read()
m = re.search(r'dependencies\s*=\s*\[(.*?)\]', text, re.DOTALL)
skip = {'software', 'homerpi'}
if m:
    for line in m.group(1).splitlines():
        line = line.strip().strip(',').strip('\"\'')
        name = re.split(r'[=!<>\[;@]', line)[0].strip().lower()
        if line and name not in skip:
            print(line)
" > "${REQS_FILE}"

if [ -s "${REQS_FILE}" ]; then
	on_chroot << EOF
python3 -m pip install --break-system-packages -r /root/homer_requirements.txt
EOF
fi

rm -f "${REQS_FILE}"
