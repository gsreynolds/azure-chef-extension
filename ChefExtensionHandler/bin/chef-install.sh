#!/bin/sh

# returns script dir
get_script_dir(){
  SCRIPT=$(readlink -f "$0")
  script_dir=`dirname $SCRIPT`
  echo "${script_dir}"
}
commands_script_path=$(get_script_dir)

. $commands_script_path/shared.sh

chef_extension_root=$commands_script_path/../

read_environment_variables $chef_extension_root

# install azure chef extension gem
install_chef_extension_gem(){
 echo "[$(date)] Installing Azure Chef Extension gem"
 gem install "$1" --no-ri --no-rdoc

  if test $? -ne 0; then
    echo "[$(date)] Azure Chef Extension gem installation failed"
    exit 1
  else
    echo "[$(date)] Azure Chef Extension gem installation succeeded"
  fi
}

curl_check(){
  echo "Checking for curl..."
  if command -v curl > /dev/null; then
    echo "Detected curl..."
  else
    echo "Installing curl..."
    if [ "$1" = "centos" -o "$1" = "rhel" -o "$1" = "linuxoracle" ]; then
      yum install -d0 -e0 -y curl
    else
      apt-get install -q -y curl
    fi
  fi
}

get_value_from_setting_file() {
  chef_value=""
  if cat $1 2>/dev/null | grep -q $2; then
    chef_value=`sed ':a;N;$!ba;s/\n//g' $1 | sed 's/.*'"${2}"'" *: *" *\(.*\)/\1/' 2>/dev/null | awk -F\" '{ print $1 }' | sed 's/[ \t]*$//'`
  fi
  echo $chef_value
}

chef_install_from_script(){
    echo "Fetching settings file"
    config_file_name=$(get_config_settings_file $chef_extension_root)
    if [ -z "$config_file_name" ]; then
      echo "Configuration error. Azure chef extension Settings file missing."
      exit 1
    fi
    echo "Reading chef-client version from settings file"
    chef_version=$(get_value_from_setting_file $config_file_name "bootstrap_version" &)
    echo "Reading chef-client release channel from settings file"
    chef_channel=$(get_value_from_setting_file $config_file_name "bootstrap_channel" &)
    echo "Reading downloaded chef-client path from settings file"
    chef_downloaded_package=$(get_value_from_setting_file $config_file_name "chef_package_path" &)
    echo "Call for Checking linux distributor"
    platform=$(get_linux_distributor)
    #check if chef-client is already installed
    if [ "$platform" = "ubuntu" -o "$platform" = "debian" ]; then
      dpkg-query -s chef > /dev/null 2>&1
    elif [ "$platform" = "centos" -o "$platform" = "rhel" -o "$platform" = "linuxoracle" ]; then
      yum list installed | grep -w "chef"
    fi
    if [ $? -ne 0 ] && [ -z "$chef_downloaded_package" ]; then
      curl_check $platform
      curl -L -o /tmp/$platform-install.sh https://omnitruck.chef.io/install.sh
      echo "Install.sh script downloaded at /tmp/$platform-install.sh"
      if [ -z "$chef_version" ] && [ -z "$chef_channel" ]; then
        echo "Installing latest chef-14 client"
        sh /tmp/$platform-install.sh -v "14" # Until Chef-15 is Verified
      elif [ ! -z "$chef_version" ] && [ -z "$chef_channel" ]; then
        echo "Installing chef client version $chef_version"
        sh /tmp/$platform-install.sh -v $chef_version
      elif [ -z "$chef_version" ] && [ ! -z "$chef_channel" ]; then
        echo "Installing latest chef client from $chef_channel"
        sh /tmp/$platform-install.sh -c $chef_channel
      else
        echo "Installing chef client version $chef_version from $chef_channel channel"
        sh /tmp/$platform-install.sh -v $chef_version -c $chef_channel
      fi
      echo "Deleting Install.sh script present at /tmp/$platform-install.sh"
      rm /tmp/$platform-install.sh -f
    elif [ $? -ne 0 ] && [ ! -z "$chef_downloaded_package" ]; then
      echo "Installing downloaded chef client from $chef_downloaded_package path"
      filename=`echo $chef_downloaded_package | sed -e 's/^.*\///'`
      filetype=`echo $filename | sed -e 's/^.*\.//'`
      install_file $filetype "$chef_downloaded_package"
    else
      echo "Chef-client is already installed"
    fi
}

########### Script starts from here ##################

chef_install_from_script

export PATH=/opt/chef/bin/:/opt/chef/embedded/bin:$PATH

# check if azure-chef-extension is installed
azure_chef_extn_gem=`gem list azure-chef-extension | grep azure-chef-extension | awk '{print $1}'`

if test "$azure_chef_extn_gem" = "azure-chef-extension" ; then
  echo "azure-chef-extension is already installed."
else
  # install azure chef extension gem
  install_chef_extension_gem "$chef_extension_root/gems/*.gem"
fi