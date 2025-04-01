#!/bin/bash


BACKUP_DIR="./backupdir"
mkdir -p "$BACKUP_DIR"


VOLUMES=$(docker volume ls -q)


for VOLUME in $VOLUMES; do
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="${BACKUP_DIR}/${VOLUME}_${TIMESTAMP}.tar.gz"

  echo "Backing up volume: $VOLUME -> $BACKUP_FILE"

  docker run --rm \
    -v "$VOLUME":/volume \
    -v "$(pwd)/$BACKUP_DIR":/backup \
    alpine \
    sh -c "tar czf /backup/$(basename "$BACKUP_FILE") -C /volume ."
done

echo "Done ✅ $BACKUP_DIR"
