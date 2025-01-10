import requests
import csv
import getpass
import pandas as pd
from colorama import Fore, Style, init

# Initialize colorama for colorful output
init(autoreset=True)

# Read configuration from config.txt
def read_config(config_file):
    config = {}
    with open(config_file, 'r') as file:
        for line in file:
            key, value = line.strip().split('=', 1)
            config[key.strip()] = value.strip()
    return config

# FortiManager details from config.txt
config_file = "config.txt"
config = read_config(config_file)
fortimanager_host = config.get("HOST")
username = config.get("USERNAME")

# Prompt user for password
password = getpass.getpass(prompt="Enter FortiManager Password: ")


# API Base URL
base_url = f"https://{fortimanager_host}/jsonrpc"

# Disable SSL warnings for self-signed certs
requests.packages.urllib3.disable_warnings()

def login():
    payload = {
        "method": "exec",
        "params": [
            {
                "url": "/sys/login/user",
                "data": {
                    "user": username,
                    "passwd": password
                }
            }
        ],
        "id": 1
    }
    response = requests.post(base_url, json=payload, verify=False)
    return response.json().get("session")

def logout(session_id):
    payload = {
        "method": "exec",
        "params": [
            {
                "url": "/sys/logout"
            }
        ],
        "session": session_id,
        "id": 1
    }
    requests.post(base_url, json=payload, verify=False)

def get_adoms(session_id):
    payload = {
        "method": "get",
        "params": [
            {
                "url": "/dvmdb/adom"
            }
        ],
        "session": session_id,
        "id": 1
    }
    response = requests.post(base_url, json=payload, verify=False)
    return [adom["name"] for adom in response.json()["result"][0]["data"]]

def get_fortigates_info(session_id, adom):
    payload = {
        "method": "get",
        "params": [
            {
                "url": f"/dvmdb/adom/{adom}/device"
            }
        ],
        "session": session_id,
        "id": 1
    }
    response = requests.post(base_url, json=payload, verify=False)
    device_info_list = []

    devices = response.json().get("result", [{}])[0].get("data", [])
    if not devices:
        print(f"{Fore.YELLOW}No devices found in ADOM: {adom}")
        return device_info_list

    for device in devices:
        device_name = device.get("name")
        ip_address = device.get("ip")
        firmware_version = device.get("os_ver")
        os_build = device.get("build")
        ha_group_name = device.get("ha_group_name", "N/A")
        platform_str = device.get("platform_str")
        serialno = device.get("sn")

        if not device_name:
            continue

        device_info_list.append({
            "ADOM": adom,
            "Firewall Name": device_name,
            "Firmware Version": firmware_version,
            "OS Build": os_build,
            "HA Group Name": ha_group_name,
            "Platform String": platform_str,
            "Serial Number": serialno,
            "IP Address": ip_address
        })

    return device_info_list

def main():
    session_id = login()
    if not session_id:
        print(f"{Fore.RED}Login failed.")
        return

    all_device_info = []

    try:
        adoms = get_adoms(session_id)
        for adom in adoms:
            device_info_list = get_fortigates_info(session_id, adom)
            all_device_info.extend(device_info_list)
    finally:
        logout(session_id)

    # Print the gathered information with colorful output
    for device in all_device_info:
        print(f"{Fore.CYAN}ADOM: {device['ADOM']}, {Fore.GREEN}Firewall Name: {device['Firewall Name']}, "
              f"{Fore.YELLOW}Firmware Version: {device['Firmware Version']}, OS Build: {device['OS Build']}, "
              f"HA Group Name: {device['HA Group Name']}, Platform String: {device['Platform String']}, "
              f"Serial Number: {device['Serial Number']}, IP Address: {device['IP Address']}")

    # Prompt user to save the information to a CSV file
    save_csv = input(f"{Fore.MAGENTA}Would you like to save this information to a CSV file? (yes/no): ").strip().lower()
    if save_csv == "yes":
        output_file = "fortigate_device_info.csv"
        df = pd.DataFrame(all_device_info)
        df.to_csv(output_file, index=False)
        print(f"{Fore.GREEN}CSV file '{output_file}' created successfully.")

if __name__ == "__main__":
    main()