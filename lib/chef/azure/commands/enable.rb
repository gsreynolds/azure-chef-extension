
# This implements the azure extension 'enable' command.

require 'chef'
require 'chef/azure/helpers/shared'
require 'chef/azure/service'

class EnableChef
  include Chef::Mixin::ShellOut
  include ChefAzure::Shared
  include ChefAzure::Config
  include ChefAzure::Reporting

  def initialize(extension_root, *enable_args)
    @chef_extension_root = extension_root
    @enable_args = enable_args
    @exit_code = 0
  end

  def run
    load_env

    report_heart_beat_to_azure(AzureHeartBeat::NOTREADY, 0, "Enabling chef-service...")

    enable_chef

    if @exit_code == 0
      report_heart_beat_to_azure(AzureHeartBeat::READY, 0, "chef-service is enabled")
    else
      report_heart_beat_to_azure(AzureHeartBeat::NOTREADY, 0, "chef-service enable failed")
    end

    return @exit_code

  end

  private
  def load_env
    @azure_heart_beat_file, @azure_status_folder, @azure_plugin_log_location, @azure_config_folder, @azure_status_file = read_config(@chef_extension_root)
  end

  def enable_chef
    # Enabling Chef involves following steps:
    # - Configure chef only on first run
    # - Install the Chef service
    # - Start the Chef service   
    begin
      configure_chef_only_once

      install_chef_service if @exit_code == 0

      enable_chef_service if @exit_code == 0

    rescue => e
      Chef::Log.error e
      report_status_to_azure "#{e} - Check log file for details", "error"
      @exit_code = 1
    ensure
      # Once process exits, we log the current process' pid
      Chef::Log.info "Process completed (pid: #{Process.pid})"
    end
    @exit_code
  end

  def install_chef_service
    @exit_code, error_message = ChefService.new.install(@azure_plugin_log_location)
    if @exit_code == 0
      report_status_to_azure "chef-service installed", "success"
    else
      report_status_to_azure "chef-service install failed - #{error_message}", "error"
    end
    @exit_code
  end

  def enable_chef_service
    @exit_code, error_message = ChefService.new.enable(@azure_plugin_log_location)
    if @exit_code == 0
      report_status_to_azure "chef-service enabled", "success"
    else
      report_status_to_azure "chef-service enable failed - #{error_message}", "error"
    end
    @exit_code
  end

  # Configuring chef involves
  #   => create bootstrap folder with client.rb, validation.pem, first_boot.json
  #   => Perform node registration executing first chef run
  #   => run the user supplied runlist from first_boot.json in async manner
  def configure_chef_only_once

    # "node-registered" file also indicates that enabled was called once and 
    # configs are already generated.
    if not File.exists?("#{bootstrap_directory}/node-registered")
      if File.directory?("#{bootstrap_directory}")
        puts "Bootstrap directory [#{bootstrap_directory}] already exists, skipping creation..."
      else
        puts "Bootstrap directory [#{bootstrap_directory}] does not exist, creating..."
        FileUtils.mkdir_p("#{bootstrap_directory}")
      end

      load_settings
    
      # Write validation key
      File.open("#{bootstrap_directory}/validation.pem", "w") do |f|
        f.write(@validation_key)
      end

      # Write client.rb
      File.open("#{bootstrap_directory}/client.rb", "w") do |f|
        f.write(override_clientrb_file(@client_rb))
      end

      # write the first_boot.json
      File.open("#{bootstrap_directory}/first-boot.json", "w") do |f|
        f.write(<<-RUNLIST
{
"run_list": [#{escape_runlist(@run_list)}]
}
RUNLIST
)
      end

      # run chef-client for first time with no runlist to register the node
      puts "Running chef client for first time with no runlist..."

      begin
        params = " -c #{bootstrap_directory}/client.rb -E _default -L #{@azure_plugin_log_location}/chef-client.log --once "
        result = shell_out("chef-client #{params}")
        result.error!
      rescue Mixlib::ShellOut::ShellCommandFailed => e
        Chef::Log.warn "chef-client run - node registration failed (#{e})"
        report_status_to_azure "#{e} - Check log file for details", "error"
        @exit_code = 1
        return
      rescue => e
        Chef::Log.error e
        report_status_to_azure "#{e} - Check log file for details", "error"
        @exit_code = 1
        return
      end

      puts "Node registered successfully"
      File.open("#{bootstrap_directory}/node-registered", "w") do |file|
        file.write("Node registered.")
      end

      # Now the run chef-client with runlist in background, as we done want enable command to wait, else long running chef-client with runlist will timeout azure.
      puts "Launching chef-client again to set the runlist"
      params = "-c #{bootstrap_directory}/client.rb -j #{bootstrap_directory}/first-boot.json -E _default -L #{@azure_plugin_log_location}/chef-client.log --once "
      child_pid = Process.spawn "chef-client #{params}"
      Process.detach child_pid
      puts "Successfully launched chef-client process with PID [#{child_pid}]"

    end
  end

  def load_settings
    # TODO - For some reason below code dervied from Powershell counter part does not work, revist if 'kd/linux-extn' branch needs to rebase with windows released branch.
    # @protected_settings = value_from_json_file_rb(handler_settings_file,'runtimeSettings','0','handlerSettings', 'protectedSettings')
    # # TODO - decode protectedSettings
    # @protected_settings_cert_thumbprint = value_from_json_file_rb(handler_settings_file, 'runtimeSettings', '0',  'handlerSettings' ,'protectedSettingsCertThumbprint')

    # @client_rb = value_from_json_file_rb(handler_settings_file, 'runtimeSettings', '0', 'handlerSettings', 'publicSettings', 'client_rb')

    # @run_list = value_from_json_file_rb(handler_settings_file, 'runtimeSettings', '0', 'handlerSettings', 'publicSettings', 'runList')

    settings_content = File.read(handler_settings_file)

    # we do this since ruby json parsing dislikes newlines in json values
    # azure sends them as is for client_rb
    settings_content = literalize_client_rb_newlines(settings_content)
    settings_hash = JSON.parse(settings_content)

    protected_settings = settings_hash["runtimeSettings"][0]["handlerSettings"]["protectedSettings"]
    @validation_key = get_validation_key(protected_settings)

    @client_rb = settings_hash["runtimeSettings"][0]["handlerSettings"]["publicSettings"]["client_rb"]
    @run_list = settings_hash["runtimeSettings"][0]["handlerSettings"]["publicSettings"]["runlist"]

  end

  def handler_settings_file
    @handler_settings_file ||=
    begin
      files = Dir.glob("#{@azure_config_folder}/*.settings").sort
      if files and not files.empty?
        files.last
      else
        error_message = "Configuration error. Azure chef extension Settings file missing."
        Chef::Log.error error_message
        report_status_to_azure error_message, "error"
        @exit_code = 1
        raise error_message
      end
    end
  end

  # Note - this assumes ascii char-set. TODO - other langs?
  def literalize_client_rb_newlines(content)
    client_rb_key_start_idx = content.index("\"client_rb\"")
    client_rb_val_start_idx = client_rb_key_start_idx + "\"client_rb\"".length + 1
 
    # move ahead till the quoted value starts
    while true
      (content[client_rb_val_start_idx] != "\"") ? client_rb_val_start_idx += 1 : break
    end
    client_rb_val_start_idx += 1
    result = content[0, client_rb_val_start_idx] 
    literalized_content = []
    literalize = true # when client_rb value ends, we turn it off and simply copy rest of content
    # Now find the end of client_rb value, literalizing till unescaped double quote "
    for i in (client_rb_val_start_idx)..(content.length - 1)
      if literalize
        if content[i] == '"'
          if content[i-1] == "\\"
            # its an escaped quote, so copy as is
          else
            # its unescaped quote, so client_rb value ends here.
            literalize = false
          end
          literalized_content.push(content[i])
        else
          # just part of client_rb value
          if content[i] == "\n"
            # literalize
            literalized_content.push('\\n')
          elsif content[i] == "\r"
            # literalize
            literalized_content.push('\\r')              
          else
            literalized_content.push(content[i])
          end
        end
      else
        literalized_content.push(content[i])
      end
    end
    result + literalized_content.join("")
  end

  def override_clientrb_file(user_client_rb)
    client_rb = <<-CONFIG
client_key        "#{bootstrap_directory}/client.pem"
validation_key    "#{bootstrap_directory}/validation.pem"
log_location  "#{@azure_plugin_log_location}/chef-client.log"
CONFIG

    "#{user_client_rb}\r\n#{client_rb}"
  end

  def escape_runlist(run_list)
    parsedRunlist = []
    run_list.split(/,\s*|\s/).reject(&:empty?).each do |item|
      if(item.match(/\s*"?recipe\[\S*\]"?\s*/))
        run_list_item = item.split(/\s*"?'?recipe\["?'?|"?'?\]"?'?/)[1]
        parsedRunlist << "\"recipe[#{run_list_item}]\""
      elsif(item.match(/\s*"?role\[\S*\]"?\s*/))
        run_list_item = item.split(/\s*"?'?role\["?'?|"?'?\]"?'?/)[1]
        parsedRunlist << "\"role[#{run_list_item}]\""
      else
        item = item.match(/\s*"?'?\[?"?'?(?<itm>\S*[^\p{Punct}])"?'?\]?"?'?\s*/)[:itm]
        parsedRunlist << "\"recipe[#{item}]\""
      end
    end
    parsedRunlist.join(",")
  end

  def get_validation_key(encrypted_text)
    require 'openssl'
    require 'base64'

    # TODO - remove hardcode of the path of the certificate
    certificate_path = "/var/lib/waagent/Certificates.pem"

    # TODO - validate if the certificate thumbprint and the thumbprint on the protectedSettings is same.
    # this step may be optional.

    # read cert & get key from the certificate
    certificate = OpenSSL::X509::Certificate.new File.read(certificate_path)
    private_key = OpenSSL::PKey::RSA.new File.read(certificate_path)

    # decrypt text
    encrypted_text = Base64.decode64(encrypted_text)
    encrypted_text = OpenSSL::PKCS7.new(encrypted_text)
    decrypted_text = encrypted_text.decrypt(private_key, certificate)

    #extract validation_key from decrypted hash
    require 'helpers/parse_json'
    require 'tempfile'
    temp_file = Tempfile.new("decrypted")
    temp_file.write(decrypted_text)
    temp_file.close
    validation_key = value_from_json_file(temp_file.path, "validation_key")
    temp_file.unlink
    return validation_key
  end
end

