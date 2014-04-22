#!/bin/sh

# returns script dir
get_script_dir(){
  SCRIPT=$(readlink -f "$0")
  script_dir=`dirname $SCRIPT`
  echo "${script_dir}"
}

chef_extension_root=$(get_script_dir)/../

# returns chef-client bebian installer
get_deb_installer(){
  pkg_file="$chef_extension_root/installer/chef-client-latest.deb"
  echo "${pkg_file}"
}

# install_file TYPE FILENAME
# TYPE is "deb"
install_file() {
  echo "Installing Chef $version"
  case "$1" in
    "deb")
      echo "installing with dpkg...$2"
      dpkg -i "$2"
      ;;
    *)
      echo "Unknown filetype: $1"
      exit 1
      ;;
  esac
  if test $? -ne 0; then
    echo "Chef Client installation failed"
    exit 1
  else
    echo "Chef Client installation succeeded"
  fi
}

# install azure chef extension gem
install_chef_extension_gem(){
 gem install "$1" --no-ri --no-rdoc

  if test $? -ne 0; then
    echo "Azure Chef Extension gem installation failed"
    exit 1
  else
    echo "Azure Chef Extension gem installation succeeded"
  fi
}

# get chef installer
chef_client_debian_installer=$(get_deb_installer)
installer_type="deb"

# install chef
install_file $installer_type "$chef_client_debian_installer"

export PATH=$PATH:/opt/chef/bin/:/opt/chef/embedded/bin

# install azure chef extension gem
install_chef_extension_gem "$chef_extension_root/gems/*.gem"
