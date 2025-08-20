#!/bin/bash

# Raspberry Pi Access Point and Web Server Setup Script
# Usage: 
#   wget -O setup.sh <github-raw-url> && chmod +x setup.sh && sudo ./setup.sh
#   or with command line options:
#   sudo ./setup.sh --apname "MyPi-AP" --appass "mypassword123"

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration variables
DEFAULT_AP_SSID="RaspberryPi-AP"
DEFAULT_AP_PASSWORD="raspberry123"
AP_IP="192.168.4.1"
DHCP_RANGE_START="192.168.4.2"
DHCP_RANGE_END="192.168.4.20"
FLASK_PORT="5000"

# Parse command line arguments
AP_SSID=""
AP_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --apname)
            AP_SSID="$2"
            shift 2
            ;;
        --appass)
            AP_PASSWORD="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root (use sudo)"
    exit 1
fi

log "Starting Raspberry Pi Access Point and Web Server Setup"

# Get AP credentials if not provided via command line
if [ -z "$AP_SSID" ]; then
    echo ""
    read -p "Enter WiFi AP name (default: ${DEFAULT_AP_SSID}): " input_ssid
    AP_SSID=${input_ssid:-$DEFAULT_AP_SSID}
fi

if [ -z "$AP_PASSWORD" ]; then
    echo ""
    while true; do
        read -p "Enter WiFi AP password (default: ${DEFAULT_AP_PASSWORD}): " input_password
        AP_PASSWORD=${input_password:-$DEFAULT_AP_PASSWORD}
        
        # Validate password length (WPA2 requires 8-63 characters)
        if [ ${#AP_PASSWORD} -ge 8 ] && [ ${#AP_PASSWORD} -le 63 ]; then
            break
        else
            error "Password must be between 8 and 63 characters long"
        fi
    done
fi

log "Using AP SSID: ${AP_SSID}"
log "Using AP Password: ${AP_PASSWORD}"

# Update system
log "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
log "Installing required packages..."
apt install -y hostapd dnsmasq python3 python3-pip python3-venv iptables-persistent

# Stop services during configuration
log "Stopping services for configuration..."
systemctl stop hostapd
systemctl stop dnsmasq

# Configure hostapd (Access Point)
log "Configuring hostapd..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Configure hostapd daemon
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

# Configure dnsmasq (DHCP server)
log "Configuring dnsmasq..."
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
cat > /etc/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},255.255.255.0,24h
EOF

# Configure dhcpcd
log "Configuring dhcpcd..."
cat >> /etc/dhcpcd.conf << EOF

# Static IP configuration for wlan0
interface wlan0
    static ip_address=${AP_IP}/24
    nohook wpa_supplicant
EOF

# Configure network interfaces
log "Configuring network interfaces..."
cat > /etc/systemd/network/08-wlan0.network << EOF
[Match]
Name=wlan0

[Network]
Address=${AP_IP}/24
IPForward=yes
IPMasquerade=yes
EOF

# Enable IP forwarding
log "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Configure iptables for NAT
log "Configuring iptables..."
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Save iptables rules
iptables-save > /etc/iptables/rules.v4

# Create application directory
log "Creating application directory..."
mkdir -p /opt/pi-webserver
cd /opt/pi-webserver

# Create Python virtual environment
log "Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

# Install Python packages
log "Installing Python packages..."
pip install flask python-dateutil

# Create the Flask web server
log "Creating Flask web server application..."
cat > /opt/pi-webserver/app.py << 'EOF'
#!/usr/bin/env python3

from flask import Flask, render_template, request, jsonify, send_file, redirect, url_for
import os
import subprocess
import json
import datetime
from pathlib import Path
import tempfile
import zipfile

app = Flask(__name__)

# Configuration file path
CONFIG_DIR = '/opt/pi-webserver/config'
os.makedirs(CONFIG_DIR, exist_ok=True)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/sync-time', methods=['POST'])
def sync_time():
    try:
        client_time = request.json.get('timestamp')
        if not client_time:
            return jsonify({'success': False, 'error': 'No timestamp provided'})
        
        # Convert milliseconds to seconds
        timestamp = int(client_time) / 1000
        dt = datetime.datetime.fromtimestamp(timestamp)
        
        # Set system time
        time_str = dt.strftime('%Y-%m-%d %H:%M:%S')
        subprocess.run(['date', '-s', time_str], check=True)
        
        # Save to hardware clock
        subprocess.run(['hwclock', '-w'], check=True)
        
        return jsonify({'success': True, 'message': f'Time synced to {time_str}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/files')
def list_files():
    try:
        path = request.args.get('path', '/')
        if not os.path.exists(path):
            return jsonify({'error': 'Path does not exist'})
        
        items = []
        for item in os.listdir(path):
            item_path = os.path.join(path, item)
            is_dir = os.path.isdir(item_path)
            size = os.path.getsize(item_path) if not is_dir else 0
            items.append({
                'name': item,
                'path': item_path,
                'is_directory': is_dir,
                'size': size
            })
        
        return jsonify({'items': sorted(items, key=lambda x: (not x['is_directory'], x['name']))})
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/download')
def download_file():
    try:
        file_path = request.args.get('path')
        if not file_path or not os.path.exists(file_path):
            return jsonify({'error': 'File does not exist'})
        
        if os.path.isdir(file_path):
            # Create a zip file for directories
            with tempfile.NamedTemporaryFile(delete=False, suffix='.zip') as tmp:
                with zipfile.ZipFile(tmp.name, 'w', zipfile.ZIP_DEFLATED) as zipf:
                    for root, dirs, files in os.walk(file_path):
                        for file in files:
                            file_path_full = os.path.join(root, file)
                            arcname = os.path.relpath(file_path_full, file_path)
                            zipf.write(file_path_full, arcname)
                
                return send_file(tmp.name, as_attachment=True, 
                               download_name=f"{os.path.basename(file_path)}.zip")
        else:
            return send_file(file_path, as_attachment=True)
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/config')
def config_page():
    try:
        config_files = []
        for file in os.listdir(CONFIG_DIR):
            if file.endswith('.txt') or file.endswith('.conf'):
                file_path = os.path.join(CONFIG_DIR, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                config_files.append({'name': file, 'content': content})
        
        return render_template('config.html', config_files=config_files)
    except Exception as e:
        return jsonify({'error': str(e)})

@app.route('/config/save', methods=['POST'])
def save_config():
    try:
        filename = request.form.get('filename')
        content = request.form.get('content')
        
        if not filename:
            return jsonify({'success': False, 'error': 'No filename provided'})
        
        file_path = os.path.join(CONFIG_DIR, filename)
        with open(file_path, 'w') as f:
            f.write(content)
        
        return jsonify({'success': True, 'message': f'Config file {filename} saved'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/config/create', methods=['POST'])
def create_config():
    try:
        filename = request.form.get('filename')
        if not filename:
            return jsonify({'success': False, 'error': 'No filename provided'})
        
        if not filename.endswith(('.txt', '.conf')):
            filename += '.txt'
        
        file_path = os.path.join(CONFIG_DIR, filename)
        if os.path.exists(file_path):
            return jsonify({'success': False, 'error': 'File already exists'})
        
        with open(file_path, 'w') as f:
            f.write('# New configuration file\n')
        
        return jsonify({'success': True, 'message': f'Config file {filename} created'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# Create HTML templates directory
log "Creating HTML templates..."
mkdir -p /opt/pi-webserver/templates

# Create main HTML template
cat > /opt/pi-webserver/templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Raspberry Pi Control Panel</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        .section { margin: 20px 0; padding: 20px; border: 1px solid #ddd; border-radius: 4px; }
        .section h2 { margin-top: 0; color: #666; }
        button { background-color: #007bff; color: white; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; margin: 5px; }
        button:hover { background-color: #0056b3; }
        .file-list { max-height: 400px; overflow-y: auto; border: 1px solid #ddd; padding: 10px; }
        .file-item { padding: 5px; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; align-items: center; }
        .file-item:hover { background-color: #f8f9fa; }
        .breadcrumb { padding: 10px; background-color: #e9ecef; border-radius: 4px; margin-bottom: 10px; }
        .status { padding: 10px; margin: 10px 0; border-radius: 4px; }
        .status.success { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .status.error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🥧 Raspberry Pi Control Panel</h1>
        
        <div class="section">
            <h2>⏰ Time Synchronization</h2>
            <p>Sync the Raspberry Pi's clock with your device's current time.</p>
            <button onclick="syncTime()">Sync Time with Device</button>
            <div id="time-status"></div>
        </div>

        <div class="section">
            <h2>📁 File Browser & Download</h2>
            <p>Browse and download files from the Raspberry Pi filesystem.</p>
            <div id="breadcrumb" class="breadcrumb">/</div>
            <div id="file-list" class="file-list">Loading...</div>
        </div>

        <div class="section">
            <h2>⚙️ Configuration Files</h2>
            <p>Manage configuration files stored on the Raspberry Pi.</p>
            <button onclick="window.location.href='/config'">Manage Config Files</button>
        </div>
    </div>

    <script>
        let currentPath = '/';

        function syncTime() {
            const timestamp = Date.now();
            const statusDiv = document.getElementById('time-status');
            
            statusDiv.innerHTML = '<div class="status">Syncing time...</div>';
            
            fetch('/sync-time', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({timestamp: timestamp})
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    statusDiv.innerHTML = `<div class="status success">${data.message}</div>`;
                } else {
                    statusDiv.innerHTML = `<div class="status error">Error: ${data.error}</div>`;
                }
            })
            .catch(error => {
                statusDiv.innerHTML = `<div class="status error">Network error: ${error}</div>`;
            });
        }

        function loadFiles(path = '/') {
            currentPath = path;
            document.getElementById('breadcrumb').textContent = path;
            
            fetch(`/files?path=${encodeURIComponent(path)}`)
            .then(response => response.json())
            .then(data => {
                if (data.error) {
                    document.getElementById('file-list').innerHTML = `<div class="status error">${data.error}</div>`;
                    return;
                }
                
                let html = '';
                if (path !== '/') {
                    const parentPath = path.split('/').slice(0, -1).join('/') || '/';
                    html += `<div class="file-item">
                        <span onclick="loadFiles('${parentPath}')" style="cursor: pointer; color: #007bff;">📁 ..</span>
                    </div>`;
                }
                
                data.items.forEach(item => {
                    const icon = item.is_directory ? '📁' : '📄';
                    const size = item.is_directory ? '' : ` (${formatBytes(item.size)})`;
                    const clickAction = item.is_directory ? 
                        `onclick="loadFiles('${item.path}')" style="cursor: pointer; color: #007bff;"` :
                        '';
                    
                    html += `<div class="file-item">
                        <span ${clickAction}>${icon} ${item.name}${size}</span>
                        ${!item.is_directory ? `<button onclick="downloadFile('${item.path}')">Download</button>` : ''}
                    </div>`;
                });
                
                document.getElementById('file-list').innerHTML = html;
            })
            .catch(error => {
                document.getElementById('file-list').innerHTML = `<div class="status error">Error loading files: ${error}</div>`;
            });
        }

        function downloadFile(path) {
            window.open(`/download?path=${encodeURIComponent(path)}`);
        }

        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }

        // Load initial file list
        loadFiles();
    </script>
</body>
</html>
EOF

# Create configuration HTML template
cat > /opt/pi-webserver/templates/config.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Configuration Files - Raspberry Pi</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        button { background-color: #007bff; color: white; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; margin: 5px; }
        button:hover { background-color: #0056b3; }
        button.success { background-color: #28a745; }
        button.danger { background-color: #dc3545; }
        .config-section { margin: 20px 0; padding: 20px; border: 1px solid #ddd; border-radius: 4px; }
        textarea { width: 100%; height: 300px; font-family: monospace; }
        .status { padding: 10px; margin: 10px 0; border-radius: 4px; }
        .status.success { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .status.error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        input[type="text"] { padding: 8px; margin: 5px; border: 1px solid #ddd; border-radius: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>⚙️ Configuration Files</h1>
        <button onclick="window.location.href='/'">← Back to Main</button>
        
        <div class="config-section">
            <h2>Create New Config File</h2>
            <input type="text" id="new-filename" placeholder="filename.txt">
            <button onclick="createConfig()">Create File</button>
        </div>

        <div id="status-area"></div>

        {% for config in config_files %}
        <div class="config-section">
            <h2>{{ config.name }}</h2>
            <textarea id="content-{{ loop.index }}">{{ config.content }}</textarea>
            <br>
            <button onclick="saveConfig('{{ config.name }}', 'content-{{ loop.index }}')" class="success">Save Changes</button>
        </div>
        {% endfor %}
    </div>

    <script>
        function saveConfig(filename, textareaId) {
            const content = document.getElementById(textareaId).value;
            const statusArea = document.getElementById('status-area');
            
            const formData = new FormData();
            formData.append('filename', filename);
            formData.append('content', content);
            
            fetch('/config/save', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    statusArea.innerHTML = `<div class="status success">${data.message}</div>`;
                } else {
                    statusArea.innerHTML = `<div class="status error">${data.error}</div>`;
                }
            })
            .catch(error => {
                statusArea.innerHTML = `<div class="status error">Network error: ${error}</div>`;
            });
        }

        function createConfig() {
            const filename = document.getElementById('new-filename').value;
            const statusArea = document.getElementById('status-area');
            
            if (!filename) {
                statusArea.innerHTML = '<div class="status error">Please enter a filename</div>';
                return;
            }
            
            const formData = new FormData();
            formData.append('filename', filename);
            
            fetch('/config/create', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    statusArea.innerHTML = `<div class="status success">${data.message}</div>`;
                    setTimeout(() => location.reload(), 1000);
                } else {
                    statusArea.innerHTML = `<div class="status error">${data.error}</div>`;
                }
            })
            .catch(error => {
                statusArea.innerHTML = `<div class="status error">Network error: ${error}</div>`;
            });
        }
    </script>
</body>
</html>
EOF

# Create systemd service for Flask app
log "Creating systemd service..."
cat > /etc/systemd/system/pi-webserver.service << EOF
[Unit]
Description=Raspberry Pi Web Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pi-webserver
Environment=PATH=/opt/pi-webserver/venv/bin
ExecStart=/opt/pi-webserver/venv/bin/python /opt/pi-webserver/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create startup script to ensure AP starts correctly
cat > /usr/local/bin/start-ap.sh << 'EOF'
#!/bin/bash

# Wait for interface to be available
sleep 10

# Restart networking services
systemctl restart dhcpcd
sleep 5
systemctl restart hostapd
systemctl restart dnsmasq

# Ensure IP forwarding is enabled
echo 1 > /proc/sys/net/ipv4/ip_forward

# Restore iptables rules
iptables-restore < /etc/iptables/rules.v4
EOF

chmod +x /usr/local/bin/start-ap.sh

# Create systemd service for AP startup
cat > /etc/systemd/system/start-ap.service << EOF
[Unit]
Description=Start Access Point
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/start-ap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
log "Enabling services..."
systemctl daemon-reload
systemctl enable hostapd
systemctl enable dnsmasq
systemctl enable pi-webserver.service
systemctl enable start-ap.service

# Create some sample configuration files
log "Creating sample configuration files..."
cat > /opt/pi-webserver/config/sample.txt << EOF
# Sample Configuration File
# This is a sample configuration file that can be edited via the web interface

# Network Settings
network.ssid=${AP_SSID}
network.password=${AP_PASSWORD}

# Server Settings  
server.port=${FLASK_PORT}
server.debug=false

# Custom Variables
custom.variable1=value1
custom.variable2=value2
custom.variable3=value3
EOF

cat > /opt/pi-webserver/config/app.conf << EOF
[general]
app_name=Raspberry Pi Control Panel
version=1.0

[network]
ap_ip=${AP_IP}
dhcp_start=${DHCP_RANGE_START}
dhcp_end=${DHCP_RANGE_END}

[security]
enable_auth=false
session_timeout=3600
EOF

# Set correct permissions
log "Setting permissions..."
chown -R root:root /opt/pi-webserver
chmod +x /opt/pi-webserver/app.py

# Disable default WiFi behavior
log "Configuring WiFi settings..."
systemctl disable wpa_supplicant

# Final message and reboot prompt
log "Setup completed successfully!"
echo ""
echo "==============================================="
echo "Raspberry Pi Access Point Setup Complete!"
echo "==============================================="
echo ""
echo "Configuration Summary:"
echo "- WiFi AP SSID: ${AP_SSID}"
echo "- WiFi Password: ${AP_PASSWORD}"
echo "- AP IP Address: ${AP_IP}"
echo "- Web Server Port: ${FLASK_PORT}"
echo "- Web Interface: http://${AP_IP}:${FLASK_PORT}"
echo ""
echo "After reboot, you can:"
echo "1. Connect to the '${AP_SSID}' WiFi network"
echo "2. Open a browser and go to http://${AP_IP}:${FLASK_PORT}"
echo "3. Use the web interface to:"
echo "   - Sync time with your mobile device"
echo "   - Browse and download files"
echo "   - Edit configuration files"
echo ""
warning "The system needs to reboot to apply all changes."
read -p "Do you want to reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting system..."
    reboot
else
    log "Please reboot manually when ready: sudo reboot"
fi