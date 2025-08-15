import datetime
import json
import logging
import os
import shutil
import subprocess
import sys
import time

from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


BACKUP_DIR = Path("/mnt/lvm-backups")
ROOT_MNT_DIR = Path("/mnt")
MNT_DIR_PREFIX = "snap_"
SNAP_POSTFIX = "_snap"


class BackupException(Exception):
    pass


@dataclass
class LvmItem():
    name: str
    size: str


@dataclass
class BackupResult:
    lv: LvmItem
    passed: bool = False
    error: Optional[BackupException] = None


class JsonFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "logger": record.name,
            "level": record.levelname,
            "time": self.formatTime(record, self.datefmt),
            "message": record.getMessage(),
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)


logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)
log_file_path = "/var/log/backup-scripts/backup.log"
file_handler = logging.FileHandler(log_file_path)
file_handler.setFormatter(JsonFormatter())  # JSON format
logger.addHandler(file_handler)


def get_all_lvs(vg: LvmItem) -> List[LvmItem]:
    cmd = ["lvs", "--reportformat", "json", vg.name]
    return _get_lvm_data(cmd, "lv")


def _get_lvm_data(cmd: List[str], data: str) -> List[LvmItem]:
    """
    data should be one of:
    - vg
    - lv
    """
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error running: {cmd}: {p.stderr}")
        raise BackupException(p.stderr)

    report = json.loads(p.stdout)
    name = f"{data}_name"
    size = f"{data}_size"
    return [
        LvmItem(name=item[name], size=item[size])
        for item in report["report"][0][data]
    ]


def create_snapshot(vg: LvmItem, lv: LvmItem, snapshot_name: str) -> None:
    vg_dev = Path("/dev").joinpath(vg.name)
    lv_dev = vg_dev.joinpath(lv.name)
    snap_dev = vg_dev.joinpath(snapshot_name)
    if snap_dev.exists():
        logger.info(f"{snap_dev.as_posix()} already exists")
        remove_snapshot_vol(snap_dev)

    cmd = ["lvcreate", "--size", lv.size.upper(), "--snapshot", "--name", snapshot_name, lv_dev.as_posix()]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error creating snapshot: {snapshot_name}: {p.stderr}")
        raise BackupException(p.stderr)


def mount_snapshot(mnt_path: Path, snapshot_dev: Path) -> None:
    cmd = ["mount", snapshot_dev.as_posix(), mnt_path.as_posix()]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error mounting {snapshot_dev.as_posix()} to {mnt_path.as_posix()}")
        raise BackupException(p.stderr)


def archive(mnt_path: Path, backup_dir: Path, backup_file: str) -> None:
    backup_location = backup_dir.joinpath(backup_file)
    cmd = ["tar", "-czf", backup_location.as_posix(), "-C", mnt_path.as_posix(), "."]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error tarring: {mnt_path.as_posix()}: {p.stderr}")
        raise BackupException(p.stderr)


def clean_up(mnt_path: Path, snapshot_dev: Path, lv_snap_mnt_path: Path):
    unmount(mnt_path)
    remove_snapshot_vol(snapshot_dev)
    delete_dir(lv_snap_mnt_path)


def unmount(mnt_path: Path):
    if not mnt_path.exists():
        return
    cmd = ["umount", mnt_path.as_posix()]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error unmounting: {mnt_path.as_posix()}: {p.stderr}")
        raise BackupException(p.stderr)


def remove_snapshot_vol(snapshot_dev: Path) -> None:
    if not snapshot_dev.exists():
        return
    logger.info(f"removing snapshot vol {snapshot_dev.as_posix()}")
    cmd = ["lvremove", "-f", snapshot_dev.as_posix()]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        logger.error(f"error removing snapshot: {snapshot_dev.as_posix()}: {p.stderr}")
        raise BackupException(p.stderr)


def delete_dir(dir: Path):
    if dir.exists():
        logger.info(f"deleting directory {dir.as_posix()}")
        shutil.rmtree(dir)


def create_dir(dir: Path, recreate=False) -> None:
    logger.info(f"creating directory {dir}")
    if dir.exists() and dir.is_dir() and recreate:
        logger.info(f"{dir} already exists, recreating")
        shutil.rmtree(dir)

    dir.mkdir(exist_ok=True)
    logger.info(f"{dir} created")


def backup_lvs(vg: LvmItem, results: List[BackupResult]) -> None:
    lvs = get_all_lvs(vg)
    lv_snap_mnt_path = None
    snapshot_dev = None
    for lv in lvs:
        result = BackupResult(lv=lv)
        logger.info(f"backing up vg: {vg.name} - lv: {lv.name}")
        try:
            lv_snap_mnt_path = ROOT_MNT_DIR.joinpath(f"{MNT_DIR_PREFIX}{lv.name}")
            create_dir(lv_snap_mnt_path, recreate=True)

            snapshot_name = f"{lv.name}{SNAP_POSTFIX}"
            create_snapshot(vg, lv, snapshot_name)

            snapshot_dev = Path(f"/dev/{vg.name}/{snapshot_name}")
            mount_snapshot(lv_snap_mnt_path, snapshot_dev)

            backup_dir = BACKUP_DIR.joinpath(lv.name)
            create_dir(backup_dir, recreate=False)

            backup_file = f"{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}.tar.gz"
            archive(lv_snap_mnt_path, backup_dir, backup_file)
            result.passed = True
        except BackupException as exc:
            result.error = exc
            result.passed = False
        finally:
            if lv_snap_mnt_path:
                unmount(lv_snap_mnt_path)
            if snapshot_dev:
                remove_snapshot_vol(snapshot_dev)
            if lv_snap_mnt_path:
                delete_dir(lv_snap_mnt_path)


        results.append(result)


def get_all_vgs() -> List[LvmItem]:
    cmd = ["vgs", "--reportformat", "json"]
    return _get_lvm_data(cmd, "vg")


def delete_old_files(days: int=30) -> None:
    now = time.time()
    cutoff = now - (days * 86400)  # 86400 seconds in a day

    deleted_files = 0

    for root, _, files in os.walk(BACKUP_DIR):
        for filename in files:
            filepath = os.path.join(root, filename)
            try:
                file_mtime = os.path.getmtime(filepath)
                if file_mtime < cutoff:
                    os.remove(filepath)
                    logger.info(f"Deleted: {filepath}")
                    deleted_files += 1
            except Exception as e:
                print(f"Failed to delete {filepath}: {e}")

    logger.info(f"\nTotal files deleted: {deleted_files}")


def main():
    logger.info("backing up logical volumes")
    vgs = get_all_vgs()
    results: List[BackupResult] = []
    for vg in vgs:
        backup_lvs(vg, results)
    logger.info(f"RESULTS: {results}")
    logger.info("cleaning up old backups")
    delete_old_files()


if __name__ == "__main__":
    main()

