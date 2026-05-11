#!/bin/bash
# by i.sharifi
green='\033[0;32m'
cyan='\033[0;36m'
red='\033[0;31m'
yellow='\033[1;33m'
bold='\033[1m'
reset='\033[0m'

logfile="/tmp/fbackup.log"

log() {
    local msg="$1"
    local mode="$2"

    timestamp="$(date +"%Y-%m-%d %H:%M:%S") - $msg"

    if [[ "$mode" == "silent" ]]; then
        echo -e "$timestamp" >> "$logfile"
    else
        echo -e "$timestamp" | tee -a "$logfile"
    fi
}

monitor_size() {
    target_path="$1"
    label="$2"

    while true; do
        if [[ -e "$target_path" ]]; then
            size=$(du -sh "$target_path" 2>/dev/null | awk '{print $1}')
            echo -ne "\r${yellow}${label}:${reset} $size          "
        fi
        sleep 1
        [[ -e "$target_path" ]] || break
    done
    echo ""
}

line="----------------------------------------------------------------------------------------"

echo -e "\n${green}${bold}*** Create Backup Link ***${reset}"
echo -en "${cyan}Enter username or domain:${reset} "
read input
log "input: $input" silent
echo -e "$line"
echo -e "${yellow}log file: $logfile ${reset}"

if [[ $input == *.* ]]; then
    if [[ -f /usr/local/directadmin/conf/directadmin.conf ]]; then
        username=$(grep -i "^$input:" /etc/virtual/domainowners | awk -F ': ' '{print $2}')
        panel="DirectAdmin"
    elif [[ -f /etc/trueuserdomains ]]; then
        username=$(grep -i "^$input:" /etc/trueuserdomains | awk -F ': ' '{print $2}')
        panel="cPanel"
    else
        echo -e "${red}❌ Unable to detect control panel.${reset}"
        log "Unable to detect control panel."
        echo -e $line >> /tmp/fbackup.log
        exit 1
    fi
    if [[ -z $username ]]; then
        echo -e "${red}❌ Domain not found.${reset}"
        log "Domain not found."
        echo -e $line >> /tmp/fbackup.log
        exit 1
    fi
    echo -e "${green}✅ Domain resolved to username:${reset} ${bold}$username${reset}"
else
    username=$input
    if [[ -x /usr/local/directadmin/directadmin ]]; then
        panel="DirectAdmin"
    elif [[ -x /scripts/pkgacct ]]; then
        panel="cPanel"
    else
        echo -e "${red}❌ Unable to detect control panel.${reset}"
        log "Unable to detect control panel."
        echo -e $line >> /tmp/fbackup.log
        exit 1
    fi
fi

if [[ ! -d /home/$username ]]; then
    echo -e "${red}❌ User '${username}' does not exist. Aborting.${reset}"
    log "Username ${username} was not found in server."
    echo -e $line >> /tmp/fbackup.log
    exit 1
fi

user_size=$(du -sh /home/$username 2>/dev/null | awk '{print $1}')

echo -e "${green}✅ User found. Starting backup...${reset}"

start_time=$(date +%s)

backup_file=""
status=0

last_step=""
last_step_printed=""

if [[ "$panel" == "DirectAdmin" ]]; then
    echo -e "${bold}${cyan}Control Panel:${reset} DirectAdmin"
    log "$panel backup started for user '$username' (home size: $user_size)."
    echo -e "$line"
    
    backup_dir="/var/www/html/$username"

    monitor_size "$backup_dir" "Backup size" &
    monitor_pid=$!
    backup_log_tmp="/tmp/da_backup_${username}_$(date +%s).log"
    touch "$backup_log_tmp"

    /usr/local/directadmin/directadmin admin-backup --destination=/var/www/html --user=$username 2>&1 | tee "$backup_log_tmp" | while read -r line; do
        if [[ "$line" == *"Backing up home"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            log "Backing up files..."
            last_step="Backing up files"
        elif [[ "$line" == *"Backing up database"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            echo -en "Backing up databases..."
            log "Backing up databases..."
            last_step="Backing up databases"
        elif [[ "$line" == *"Backing up E-Mail"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            echo -en "Backing up email..."
            log "Backing up email..."
            last_step="Backing up email"
        fi
    done
    log "********** Full DirectAdmin backup output **********" silent
    cat "$backup_log_tmp" >> "$logfile"
    rm -f "$backup_log_tmp"
    log "********** End Full DirectAdmin backup output **********" silent

    status=${PIPESTATUS[0]}
    if [[ -n "$last_step" && $status -eq 0 ]]; then
        echo -e " ${green}SUCCESS${reset}"
        log "$last_step completed successfully."
    fi
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
    backup_file=$(ls -t /var/www/html | grep "$username" | head -n1)

backup_path="/var/www/html/$backup_file"
if [[ ! -f "$backup_path" ]]; then
    echo -e "${red}❌ Backup file not found.${reset}"
    log "ERROR: Backup file not found after backup process."
    echo -e $line >> /tmp/fbackup.log
    exit 1
fi

# if backup file is lower than 2MB its fail
backup_size_bytes=$(stat -c %s "$backup_path")
if [[ $backup_size_bytes -lt 600 ]]; then
    echo -e "${red}❌ Backup seems corrupted or too small (${backup_size_bytes} bytes).${reset}"
    log "ERROR: Backup file too small (${backup_size_bytes} bytes), possible failure."
    echo -e $yellow"Check /tmp/fbackup.log for more details."$reset
    echo -e $line >> /tmp/fbackup.log
    exit 1
fi


elif [[ "$panel" == "cPanel" ]]; then
    echo -e "${bold}${cyan}Control Panel:${reset} cPanel"
    log "$panel backup started for user '$username' (home size: $user_size)."
    echo -e "$line"
    
    build_dir="/var/www/html/cpmove-${username}"
    archive_file="/var/www/html/cpmove-${username}.tar.gz"

    monitor_size "$build_dir" "Temp Backup size" &
    monitor_pid=$!


    /scripts/pkgacct $username /var/www/html 2>&1 | while read -r line; do
    
        if [[ "$line" == *"Creating Archive"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            kill $monitor_pid 2>/dev/null
            wait $monitor_pid 2>/dev/null

            echo -e "\n${cyan}Creating archive...${reset}"

            #monitor_size "$archive_file" "Finall Backup size" &
            #monitor_pid=$!

            log "Backing up files..."
            last_step="Backing up files"
        elif [[ "$line" == *"Backing up MySQL"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            echo -en "Backing up databases..."
            log "Backing up databases..."
            last_step="Backing up databases"
        elif [[ "$line" == *"Backing up mail"* ]]; then
            if [[ -n "$last_step" ]]; then
                echo -e " ${green}SUCCESS${reset}"
                log "$last_step completed successfully."
            fi
            echo -en "Backing up email..."
            log "Backing up email..."
            last_step="Backing up email"
        fi
    done

    status=${PIPESTATUS[0]}
    if [[ -n "$last_step" && $status -eq 0 ]]; then
        echo -e " ${green}SUCCESS${reset}"
        log "$last_step completed successfully."
    fi
kill $monitor_pid 2>/dev/null
wait $monitor_pid 2>/dev/null
    backup_file=$(ls -t /var/www/html | grep "$username" | grep cpmove | head -n1)
    #mv "/home/$backup_file" /var/www/html/ 2>/dev/null
fi

if [[ $status -ne 0 ]]; then
    if [[ -n "$last_step" ]]; then
        echo -e " ${red}FAILED${reset}"
        log "ERROR: $last_step failed."
    fi
    echo -e "${red}❌ Backup failed with exit code $status.${reset}"
    log "ERROR: Backup failed with exit code $status."
    echo -e $line >> /tmp/fbackup.log
    exit 1
fi

if [[ -z $backup_file || ! -f /var/www/html/$backup_file ]]; then
    echo -e "${red}❌ Backup file not found.${reset}"
    log "ERROR: Backup file not found after backup process."
    echo -e $line >> /tmp/fbackup.log
    exit 1
fi

chmod 755 /var/www/html/$backup_file
chown root:root /var/www/html/$backup_file

end_time=$(date +%s)
duration=$((end_time - start_time))
hostname=$(cat /etc/hostname)
echo ""
log "Backup completed successfully. File: $backup_file"
log "Duration: ${duration} seconds."
echo -e $line >> /tmp/fbackup.log

echo -e "${green}✅ Backup completed successfully.${reset}"
echo -e "$line"
echo -e "${bold}${cyan}Download link:${reset}\n${yellow}https://$hostname/$backup_file${reset}"
echo -e "$line\n"
