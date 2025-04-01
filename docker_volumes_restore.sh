#!/bin/bash


BACKUP_DIR="./backupdir"

for BACKUP_FILE in "$BACKUP_DIR"/*.tar.gz; do
  [ -e "$BACKUP_FILE" ] || continue

  BASENAME=$(basename "$BACKUP_FILE")
  VOLUME_NAME=$(echo "$BASENAME" | sed -E 's/_20[0-9]{6}_[0-9]{6}\.tar\.gz//')

  echo "Restoring backup: $BACKUP_FILE -> volume: $VOLUME_NAME"

  docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME"

  docker run --rm \
    -v "$VOLUME_NAME":/volume \
    -v "$(pwd)/$BACKUP_DIR":/backup \
    alpine \
    sh -c "cd /volume && tar xzf /backup/$(basename "$BACKUP_FILE")"
done

echo "✅ All available backups restored"
