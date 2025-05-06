#!/usr/bin/env python3
# Script to check unsupported items and discovery rules in Zabbix 7 and export results to CSVs grouped by host and template
# https://github.com/fsolen/

import requests
import getpass
import csv

def zabbix_api(method, params, auth=None):
    response = requests.post(
        f"{ZABBIX_URL}/api_jsonrpc.php",
        json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
            "auth": auth,
        },
        headers={"Content-Type": "application/json"}
    )
    response.raise_for_status()
    data = response.json()

    if "error" in data:
        print(f"\nZabbix API Error ({method}): {data['error']['message']} - {data['error']['data']}")
        exit(1)

    return data["result"]

def prompt_credentials():
    global ZABBIX_URL
    while True:
        url = input("Enter Zabbix URL (e.g. http://localhost/zabbix): ").strip().rstrip('/')
        if url:
            ZABBIX_URL = url
            break
        else:
            print("Please enter a valid Zabbix URL.")
    user = input("Username: ").strip()
    password = getpass.getpass("Password: ").strip()
    return user, password

def check_hosts(auth_token, item_export_list, lld_export_list):
    hosts = zabbix_api("host.get", {
        "output": ["hostid", "name"],
        "filter": {"status": "0"}  # only monitored hosts
    }, auth_token)

    print(f"\nChecking {len(hosts)} monitored hosts...\n")

    for host in hosts:
        print(f"Host: {host['name']}")

        items = zabbix_api("item.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        for item in items:
            item_export_list.append([
                host["name"],
                "Unsupported Item",
                item["name"],
                item["error"].replace('\n', ' ').replace('\r', ' ')
            ])

        llds = zabbix_api("discoveryrule.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        for lld in llds:
            lld_export_list.append([
                host["name"],
                "Unsupported Discovery Rule",
                lld["name"],
                lld["error"].replace('\n', ' ').replace('\r', ' ')
            ])

def export_to_csv(filename, header, data):
    with open(filename, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        writer.writerow(header)
        writer.writerows(data)
    print(f"Exported: {filename}")

def main():
    user, password = prompt_credentials()

    print("Authenticating to Zabbix...")
    auth_token = zabbix_api("user.login", {
        "username": user,
        "password": password
    })

    item_export_list = []
    lld_export_list = []

    check_hosts(auth_token, item_export_list, lld_export_list)

    export_to_csv("zabbix_unsupported_items_by_host.csv", ["Host", "Type", "Name", "Error"], item_export_list)
    export_to_csv("zabbix_unsupported_discovery_rules_by_host.csv", ["Host", "Type", "Name", "Error"], lld_export_list)

    print("\nFull unsupported item check complete.")

if __name__ == "__main__":
    main()
