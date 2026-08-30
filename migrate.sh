for key in $(docker exec veraxi-redis-1 redis-cli KEYS "tenant:local_personal_user:*"); do
    new_key=$(echo $key | sed 's/local_personal_user/2b0d4cab-503e-4827-91d6-5806e587b15f/')
    echo "Renaming $key to $new_key"
    docker exec veraxi-redis-1 redis-cli RENAME "$key" "$new_key"
done
