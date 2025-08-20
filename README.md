# bfgate
Single script configuration and installation of raspberry pi remote management website, including configuring the pi as an access point and starting a webserver to provide the remote functionality.

Key Features:
1. WiFi Access Point Setup

Creates an AP with SSID "RaspberryPi-AP" and password "raspberry123"
Configures DHCP to assign IPs (192.168.4.2-192.168.4.20)
Sets up IP forwarding and NAT routing
Configures the Pi's AP IP as 192.168.4.1

2. Python Environment

Installs Python3 if not present
Creates a virtual environment for the Flask app
Installs required packages (Flask, python-dateutil)

3. Flask Web Server

Time Sync: Web interface to sync Pi's clock with mobile device
File Browser: Browse and download any files from the filesystem
Config Manager: Edit configuration files via web interface
Serves on port 5000 with a responsive web UI

4. Auto-start Configuration

Creates systemd services that start before user login
Ensures AP and web server start on boot
Handles service dependencies properly

Installation Process:

Connect Pi to internet (via Ethernet or initial WiFi setup)
Download and run the script:
bashwget -O setup.sh https://raw.githubusercontent.com/yourusername/yourrepo/main/setup.sh
chmod +x setup.sh
sudo ./setup.sh

Reboot when prompted
Connect to "RaspberryPi-AP" WiFi network
Access web interface at http://192.168.4.1:5000

Web Interface Features:

🕐 Time Sync: One-click time synchronization with your device
📁 File Browser: Navigate filesystem, download files/folders as ZIP
⚙️ Config Editor: Create and edit configuration files with web forms

Customization:
You can easily modify the configuration variables at the top of the script:

AP_SSID and AP_PASSWORD for WiFi credentials
AP_IP and DHCP range for network settings
FLASK_PORT for web server port

The script creates sample configuration files that demonstrate how users can edit system variables through the web interface. The configuration files are stored in /opt/pi-webserver/config/ and can be managed via the web UI.

Command Line Arguments
You can provide the AP credentials directly:
bashsudo ./setup.sh --apname "MyCustomAP" --appass "mypassword123"

Interactive Prompts
If no command line arguments are provided, the script will ask for:

AP Name: Press Enter for default "RaspberryPi-AP"
AP Password: Press Enter for default "raspberry123"

Password Validation
The script validates that the WiFi password meets WPA2 requirements (8-63 characters) and will re-prompt if invalid.
Usage Examples:

With command line arguments:
bashwget -O setup.sh https://raw.githubusercontent.com/user/repo/main/setup.sh
chmod +x setup.sh
sudo ./setup.sh --apname "CoffeeShop-Pi" --appass "supersecure2024"

Interactive mode:
bashsudo ./setup.sh
# Script will prompt:
# Enter WiFi AP name (default: RaspberryPi-AP): [user types or presses Enter]
# Enter WiFi AP password (default: raspberry123): [user types or presses Enter]

Mixed usage (only specify one parameter):
bashsudo ./setup.sh --apname "MyPi"
# Script will only prompt for password
