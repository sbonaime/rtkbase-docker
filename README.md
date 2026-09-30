# RTKBase Docker

Simplified installation of RTKBase in a Docker container for ARM routers (e.g., Teltonika RUTC50) and macOS Apple Silicon.

## 📋 Requirements

- **For macOS**:
  - [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.
  - macOS Apple Silicon (M1, M2, M3, etc.).
- **For Teltonika Router**:
  - Teltonika RUTC50 (or compatible ARM router).
  - USB GNSS receiver (e.g., UM980, ...)
  - If using a USB drive, an USB hub



## 🚀 Quick Start (macOS Apple Silicon)

1. **Build the image**:
   ```bash
   ./build.sh
   ```
2. **Run the container**:
   ```bash
   HOST_DATA_DIR=./rtkbase-data docker compose up -d
   ```
3. **Access the interface**:
   Open your browser at: `http://localhost:8888`

## 🛠️ Deployment on Router (Teltonika RUTC50)

### 📦 Installation Directory & Storage
The container and its data must be stored in a dedicated installation directory on the router.

**Important**: If you use a USB flash drive for this installation directory, you will need a **USB hub** to connect both the GNSS receiver and the USB drive simultaneously.

The installation directory must use a Linux-native filesystem (**ext4**). FAT32/exFAT are not supported because Docker's `overlay2` storage driver requires specific symlinks and permissions.

**To format a USB drive to ext4 (⚠️ this erases all data):**
```bash
mkfs.ext4 -F /dev/sda
```

### 🚀 Setup Steps

1. **Transfer the image**:
   1. Build the image on Mac
   ```bash
   ./build.sh
   ```
   1. Transfer the generated `.tar.gz` file to the router via `scp` (e.g., to `/mnt/sda/docker/`).
2. **Load the image on the router**:
   ```bash
   docker load -i /mnt/sda/docker/rtkbase-vX.Y.Z.tar.gz
   ```
3. **Configure Docker storage**:
   Point Docker's storage to your installation directory (e.g., `/mnt/sda/docker/data`) to avoid filling up the internal flash:
   ```bash
   rm -f /var/run/docker.pid
   uci set dockerd.globals.enabled='1'
   uci set dockerd.globals.data_root='/mnt/sda/docker/data'
   uci commit dockerd

   mkdir -p /mnt/sda/docker/data
   mkdir -p /mnt/sda/docker/rtkbase-data
   dockerd --data-root=/mnt/sda/docker/data > /mnt/sda/docker/dockerd.log 2>&1 &
   ```
4. **Run the container**:
   Use the provided startup script:
   ```bash
   chmod +x /mnt/sda/docker/start-rtkbase-rutc.sh
   /mnt/sda/docker/start-rtkbase-rutc.sh
   ```
   The script is idempotent: it removes any pre-existing `rtkbase` container first, waits for `dockerd` and the GNSS USB device to be ready, then (re)creates the container.

   *Note: If your GNSS device uses a different path, you can override the detection glob:*
   ```bash
   GNSS_DEVICE_GLOB='/dev/usb_serial_*' /mnt/sda/docker/start-rtkbase-rutc.sh
   ```

5. **Web Access**:
   The interface is accessible at: `http://<router-ip>:8888` (or the port configured in the script). In the web UI, configure the GNSS receiver port as `/dev/ttyGNSS0`.

### 🔄 Automatic Start at Boot
Because the container definition survives reboots when stored on external storage, a simple `docker run` would fail with a "Conflict" error. The `start-rtkbase-rutc.sh` script solves this by cleaning up previous instances.

To run it automatically at boot, add it as a **RutOS startup script**:
In the router's web UI, go to **System → Maintenance → Custom scripts**, and add the path to the script in the "Startup script" section.

## Container Management
- **Stop the container**:
````bash
docker stop rtkbase
````
- **delete the container**:
````bash
 docker rm rtkbase
````

## 📌 Key Points
- **Web Interface**: Accessible on port **8888**.
- **Persistence**: Data and configurations are saved in the `rtkbase-data` folder.
- **Services**: systemd service states are automatically saved and restored upon container restart.
- **Network**: The container uses `host` mode to ensure data flows (port 2101) are not blocked.
