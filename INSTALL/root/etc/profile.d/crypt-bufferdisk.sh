if [ -f /mnt/bufferdisk/bazaar/NOT_MOUNTED ]; then
        echo .
        echo "Bufferdisk is not mounted. Please enter password"
        /opt/AmutaQ!/tools/mount_bufferdisk
fi
