import csv
import subprocess
import socket
from colorama import Fore, Style, init

# Initialize colorama
init(autoreset=True)

def test_port(ip, port):
    """
    Uses PowerShell's Test-NetConnection to test if the given port is open on the IP.
    """
    command = f"powershell -Command \"Test-NetConnection -ComputerName {ip} -Port {port}\""
    try:
        result = subprocess.run(command, capture_output=True, text=True, shell=True)
        output = result.stdout
        if "TcpTestSucceeded" in output and "True" in output:
            return True
        else:
            return False
    except Exception as e:
        print(f"{Fore.RED}Error testing {ip}: {e}")
        return False



def process_csv(input_csv, output_csv, port=541):
    """
    Reads the input CSV, tests port 541 for each IP, and writes the results to a new CSV file.
    """
    results = []
    with open(input_csv, mode="r") as file:
        reader = csv.DictReader(file)
        for row in reader:
            ip = row.get("Non-RFC1918 IP")
            if not ip:
                continue
            
            print(f"{Fore.YELLOW}Testing {ip} on port {port}...")
            is_open = test_port(ip, port)
            status = "Open" if is_open else "Closed"
            color = Fore.GREEN if is_open else Fore.RED
            print(f"{color}IP {ip}: Port {port} is {status}")

            # Save the result
            results.append({
                "IP": ip,
                "Port": port,
                "Status": status
            })

    # Write results to a new CSV
    with open(output_csv, mode="w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["IP", "Port", "Status"])
        writer.writeheader()
        writer.writerows(results)

    print(f"{Fore.CYAN}Results have been saved to {output_csv}")

def main():
    input_csv = "./Networking/FMG/non_rfc1918_ips.csv"  # Input from the previous script
    output_csv = "./Networking/FMG/port_541_test_results.csv"  # Output CSV file for port 541 test results
    process_csv(input_csv, output_csv)

if __name__ == "__main__":
    main()