require "set"

module VMC::Cli::ManifestHelper
  include VMC::Cli::ServicesHelper

  DEFAULTS = {
    "url" => "${name}.${target-base}",
    "mem" => "128M",
    "instances" => 1
  }

  MANIFEST = "manifest.yml"

  YES_SET = Set.new ["y", "Y", "yes", "YES"]

  # take a block and call it once for each app to push/update.
  # with @application and @app_info set appropriately
  def each_app(panic = true)
    if @manifest and all_apps = @manifest["applications"]
      where = File.expand_path @path
      single = false

      all_apps.each do |path, info|
        app = File.expand_path "../" + path, manifest_file
        if where.start_with?(app)
          @application = app
          @app_info = info
          yield info["name"]
          single = true
          break
        end
      end

      unless single
        if where == File.expand_path "../", manifest_file
          ordered_by_deps(all_apps).each do |path, info|
            app = File.expand_path "../" + path, manifest_file
            @application = app
            @app_info = info
            yield info["name"]
          end
        else
          err "Path '#{@path}' is not known to manifest '#{manifest_file}'."
        end
      end
    else
      @application = @path
      @app_info = @manifest
      if @app_info
        yield @app_info["name"]
      elsif panic
        err "No applications."
      end
    end

    nil
  ensure
    @application = nil
    @app_info = nil
  end

  def interact(many = false)
    @manifest ||= {}
    configure_app many
  end

  def target_manifest
    @options[:manifest] || MANIFEST
  end

  def save_manifest(save_to = nil)
    save_to ||= target_manifest

    File.open save_to, "w" do |f|
      f.write @manifest.to_yaml
    end

    say "Manifest written to #{save_to}."
  end

  def configure_app(many = false)
    name = manifest("name") ||
      set(ask("Application Name", :default => manifest("name")), "name")

    url_template = manifest("url") || DEFAULTS["url"]
    url_resolved = url_template.dup
    resolve_lexically url_resolved

    url = ask "Application Deployed URL", :default => url_resolved

    url = url_template if url == url_resolved

    # common error case is for prompted users to answer y or Y or yes or
    # YES to this ask() resulting in an unintended URL of y. Special
    # case this common error
    url = DEFAULTS["url"] if YES_SET.member? url

    set url, "url"

    unless manifest "framework"
      framework = detect_framework
      set framework.name, "framework", "name"
      set { "mem"         => framework.mem,
            "description" => framework.description,
            "exec"        => framework.exec
          },
          "framework",
          "info"
    end

    set ask(
      "Memory reservation",
      :default =>
        manifest("mem") ||
          manifest("framework", "info", "mem") ||
          DEFAULTS["mem"],
      :choices => ["128M", "256M", "512M", "1G", "2G"]
    ), "mem"

    set ask(
      "How many instances?",
      :default => manifest("instances") || DEFAULTS["instances"]
    ), "instances"

    unless manifest "services"
      user_services = client.services
      user_services.sort! { |a, b| a[:name] <=> b[:name] }

      unless user_services.empty?
        if ask "Bind existing services to '#{name}'?", :default => false
          bind_services user_services
        end
      end

      services = client.services_info
      unless services.empty?
        if ask "Create services to bind to '#{name}'?", :default => false
          create_services(services.values.collect(&:keys).flatten)
        end
      end
    end

    if many and ask("Configure for another application?", :default => false)
      @application = ask "Application path?"
      configure_app
    end
  end

  def set(what, *where)
    where.unshift "applications", @application

    which = @manifest
    where.each_with_index do |k, i|
      if i + 1 == where.size
        which[k] = what
      else
        which = (which[k] ||= {})
      end
    end

    what
  end

  # Detect the appropriate framework.
  def detect_framework(prompt_ok = true)
    framework = VMC::Cli::Framework.detect @application, frameworks_info
    framework_correct = ask "Detected a #{framework}, is this correct?", :default => true if prompt_ok && framework
    if prompt_ok && (framework.nil? || !framework_correct)
      display "#{"[WARNING]".yellow} Can't determine the Application Type." unless framework
      framework = nil unless framework_correct
      framework = VMC::Cli::Framework.lookup(
        ask(
          "Select Application Type",
          :indexed => true,
          :default => framework,
          :choices => VMC::Cli::Framework.known_frameworks
        )
      )
      display "Selected #{framework}"
    end

    framework
  end

  def bind_services(user_services, chosen = 0)
    svcname = ask "Which one?",
      :indexed => true,
      :choices => user_services.collect { |p| p[:name] }

    svc = user_services.find { |p| p[:name] == svcname }

    set svc[:vendor], "services", svcname, "type"

    if chosen + 1 < user_services.size && ask("Bind another?", :default => false)
      bind_services user_services, chosen + 1
    end
  end

  def create_services(services)
    svcs = services.collect(&:to_s).sort!

    configure_service ask("What kind of service?",
      :indexed => true,
      :choices => svcs
      )

    create_services services if ask "Create another?", :default => false
  end

  def configure_service(vendor)
    default_name = random_service_name vendor
    name = ask "Specify the name of the service", :default => default_name

    set vendor, "services", name, "type"
  end

  private
    def ordered_by_deps(apps, abspaths = nil, processed = Set[])
      unless abspaths
        abspaths = {}
        apps.each do |p, i|
          ep = File.expand_path "../" + p, manifest_file
          abspaths[ep] = i
        end
      end

      ordered = []
      apps.each do |path, info|
        epath = File.expand_path "../" + path, manifest_file

        if deps = info["depends-on"]
          dep_apps = {}
          deps.each do |dep|
            edep = File.expand_path "../" + dep, manifest_file

            err "Circular dependency detected." if processed.include? edep

            dep_apps[dep] = abspaths[edep]
          end

          processed.add epath

          ordered += ordered_by_deps(dep_apps, abspaths, processed)
          ordered << [path, info]
        elsif not processed.include? epath
          ordered << [path, info]
          processed.add epath
        end
      end

      ordered
    end

end
