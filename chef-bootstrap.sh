#!/usr/bin/env bash

rubygems_version="1.3.7"

# TODO somehow inject this as part of the bootstrap recipes?
function _setup_iptables {
cat > /etc/iptables.rules <<EOF
*filter
# Allow local loopback services
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Allow ssh and web services
-A INPUT -p tcp --dport ssh -i eth0 -j ACCEPT
-A INPUT -p tcp --dport 80 -i eth0 -j ACCEPT
-A INPUT -p tcp --dport 443 -i eth0 -j ACCEPT
-A INPUT -p tcp --dport 444 -i eth0 -j ACCEPT

# Allow pings
-A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT

# Allow traffic already established to continue
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outgoing traffic and disallow any passthroughs
-A INPUT -j DROP
-A OUTPUT -j ACCEPT
-A FORWARD -j DROP

COMMIT
EOF

mkdir -p /etc/network/if-pre-up.d/
cat > /etc/network/if-pre-up.d/iptables << EOF
#!/bin/bash
/sbin/iptables-restore < /etc/iptables.rules
EOF
chmod 0755 /etc/network/if-pre-up.d/iptables
/sbin/iptables-restore < /etc/iptables.rules
}

function usage {
    echo "usage: $0 <client|server> <server-url>"
}

if [[ $# != 2 ]]; then
  if [[ $1 != 'server' ]]; then
    usage
    exit
  fi
fi

if [[ $1 != 'server' && $1 != 'client' ]]; then
    usage
    exit
fi

bootstrap_type="$1"

if [[ $1 == 'server' && $2 == '' ]]; then
  server_url="http://localhost:4000"
else
  server_url="$2"
fi

_setup_iptables

# Update sources
apt-get update -y

# Install required packages
apt-get install -y ruby ruby-dev libopenssl-ruby build-essential wget ssl-cert

# Install Rubygems from source
cd /tmp
wget "http://production.cf.rubygems.org/rubygems/rubygems-${rubygems_version}.tgz"
tar xzf "rubygems-${rubygems_version}.tgz"
cd "rubygems-${rubygems_version}"
ruby setup.rb -q --no-format-executable

# Disable Rubygems RDoc and RI generation
cat > /etc/gemrc <<EOF
gem: --no-ri --no-rdoc
EOF

# Install Chef
gem install chef

# Create Chef Solo config
cat > /tmp/solo.rb <<EOF
file_cache_path "/tmp/chef-solo"
cookbook_path "/tmp/chef-solo/cookbooks"
recipe_url "http://s3.amazonaws.com/chef-solo/bootstrap-latest.tar.gz"
EOF

# Create Chef server bootstrap config
cat > /tmp/chef-server.json <<EOF
{
  "chef": {
    "server_url": "$server_url",
    "webui_enabled": true
  },
  "run_list": [ "recipe[chef::bootstrap_server]", "recipe[chef::server_proxy]" ]
}
EOF

# Create Chef client bootstrap config
cat > /tmp/chef-client.json <<EOF
{
  "chef": {
    "server_url": "$server_url"
  },
  "run_list": [ "recipe[chef::bootstrap_client]" ]
}
EOF

if [[ $bootstrap_type = 'client' ]]; then
    chef-solo -c /tmp/solo.rb -j /tmp/chef-client.json
fi

if [[ $bootstrap_type = 'server' ]]; then
    chef-solo -c /tmp/solo.rb -j /tmp/chef-server.json
fi
