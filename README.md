# Introduction

# Roles

# New Host
This section explains the steps that need to be taken before a new host can be added to the
inventory file.

## Raspbian Host
* Enabled ssh:
    * Once the boot usb has been created, add an ssh file to the root directory of the boot partition.
    * Create the file:
    ```bash
    touch /media/rhoulihan/bootfs/ssh
    ```
* Add a hostname:
    * Edit the file `/media/rhoulihan/rootfs/etc/hostname`
* Add the hla user:
    * Boot up the raspberry pi
    * Login with the default pi user
    * Add the hla user
        * `sudo useradd -s /bin/bash -m hla`
    * Add a password for the new hla user
        * `sudo passwd hla`
* Add hla user to sudoers:
    * Add hla to sudoers
        * `usermod -aG sudo hla`
    * Test that hla has sudo access:
        * `sudo su hla`
        * `sudo apt update`
* Update hla so that he doesn't have to enter his password to run sudo commends
* Add hla users public key to the host
    * https://pimylifeup.com/raspberry-pi-ssh-keys/
    * Test that you can log in with the ssh keys
    * You may have to add the new host to the ~/.ssh/config file
* Remove password authentication for the user hla
    * https://pimylifeup.com/raspberry-pi-ssh-keys/
* Delete the `pi` user
* Update DNS table:
    * Add the IP address of the new host to the DNS table of the router.
