import csv
import requests
from colorama import Fore, Style, init
import urllib3
import re

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Initialize colorama
init(autoreset=True)

# Define regex for non-RFC 1918 IP addresses
NON_RFC1918_REGEX = re.compile(
    r"^(?!10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|255\.|0\.0\.0\.0|169\.).*"
)

def load_config(file_path="./config.txt"):
    """
    Load FortiManager connection details from a config file.
    """
    config = {}
    with open(file_path, "r") as file:
        for line in file:
            key, value = line.strip().split("=", 1)
            config[key.strip()] = value.strip()
    return config

def login_to_fortimanager(host, username, password):
    """
    Log in to the FortiManager and return the session token.
    """
    url = f"https://{host}/jsonrpc"
    payload = {
        "method": "exec",
        "params": [{"url": "sys/login/user", "data": {"user": username, "passwd": password}}],
        "id": 1
    }
    response = requests.post(url, json=payload, verify=False)
    response.raise_for_status()
    result = response.json()
    if result["result"][0]["status"]["code"] != 0:
        raise Exception("Failed to log in to FortiManager")
    return result["session"]

def get_adoms(host, session):
    """
    Retrieve a list of ADOMs from FortiManager.
    """
    url = f"https://{host}/jsonrpc"
    payload = {
        "method": "get",
        "params": [{"url": "dvmdb/adom"}],
        "session": session,
        "id": 1
    }
    response = requests.post(url, json=payload, verify=False)
    response.raise_for_status()
    return response.json()["result"][0]["data"]

def get_devices_in_adom(host, session, adom_name):
    """
    Retrieve the list of devices in a given ADOM.
    """
    url = f"https://{host}/jsonrpc"
    payload = {
        "method": "get",
        "params": [{"url": f"dvmdb/adom/{adom_name}/device"}],
        "session": session,
        "id": 1
    }
    response = requests.post(url, json=payload, verify=False)
    response.raise_for_status()
    return response.json()["result"][0]["data"]

def get_device_interfaces(host, session, adom_name, device_name):
    """
    Retrieve the interfaces of a device under /pm/config/device/{device_name}/vdom/root/system/interface.
    """
    url = f"https://{host}/jsonrpc"
    payload = {
        "method": "get",
        "params": [{"url": f"pm/config/device/{device_name}/vdom/root/system/interface"}],
        "session": session,
        "id": 1
    }
    response = requests.post(url, json=payload, verify=False)
    response.raise_for_status()
    return response.json()["result"][0]["data"]

def extract_non_rfc1918_ips(interfaces):
    """
    Extract non-RFC 1918 IP addresses from device interfaces.
    """
    non_rfc1918_ips = []
    for interface in interfaces:
        if "ip" in interface:
            ips = interface["ip"]
            # Handle single IP or list of IPs
            if isinstance(ips, str):
                ips = [ips]
            for ip in ips:
                if NON_RFC1918_REGEX.match(ip):
                    non_rfc1918_ips.append(ip)
    return non_rfc1918_ips

def process_adoms(host, session, output_csv):
    """
    Loops through ADOMs, checks device connection status, and writes results to a CSV.
    """
    results = []
    adoms = get_adoms(host, session)

    for adom in adoms:
        adom_name = adom["name"]
        print(f"{Fore.CYAN}Checking ADOM: {adom_name}")
        devices = get_devices_in_adom(host, session, adom_name)

        for device in devices:
            device_name = device["name"]
            is_connected = device.get("conn_status") == 1
            status = "Connected" if is_connected else "Disconnected"
            color = Fore.GREEN if is_connected else Fore.RED

            # Retrieve non-RFC1918 IPs
            interfaces = get_device_interfaces(host, session, adom_name, device_name)
            non_rfc1918_ips = extract_non_rfc1918_ips(interfaces)

            print(f"{color}Device: {device_name} | Status: {status} | Non-RFC1918 IPs: {', '.join(non_rfc1918_ips) if non_rfc1918_ips else 'None'}")
            results.append({
                "ADOM": adom_name,
                "Device Name": device_name,
                "Status": status,
                "Non-RFC1918 IPs": ", ".join(non_rfc1918_ips) if non_rfc1918_ips else "None"
            })

    # Write results to a CSV
    with open(output_csv, mode="w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["ADOM", "Device Name", "Status", "Non-RFC1918 IPs"])
        writer.writeheader()
        writer.writerows(results)

    print(f"\n{Fore.CYAN}Results have been saved to {output_csv}")

def main():
    config = load_config()  # Load connection details
    host = config["HOST"]
    username = config["USERNAME"]
    password = config["PASSWORD"]

    session = login_to_fortimanager(host, username, password)  # Login to FortiManager
    output_csv = "device_connection_status_with_ips.csv"  # Output CSV file
    process_adoms(host, session, output_csv)  # Process ADOMs and devices

if __name__ == "__main__":
    main()