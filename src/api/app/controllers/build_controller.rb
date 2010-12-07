class BuildController < ApplicationController

  def index
    valid_http_methods :get, :post, :put

    prj = DbProject.find_by_name params[:project]
    pkg = DbPackage.find_by_project_and_name( params[:project], params[:package] )  if prj and params[:package]

    # todo: check if prj.nil?/pkg.nil? is sufficient
    raise DbProject::PrjAccessError.new "" unless DbProject.check_access?(prj)
    # returns <binarylist /> on unkown package !
    # normally we'd do e.g.: raise DbPackage::PkgAccessError.new "" unless DbPackage.check_access?(pkg)
    render :text => "<binarylist />", :content_type => "text/xml"  unless DbPackage.check_access?(pkg)

    pass_to_backend 
  end

  def project_index
    valid_http_methods :get, :post, :put
    prj = DbProject.find_by_name params[:project]

    raise DbProject::PrjAccessError.new "" unless DbProject.check_access?(prj)

    path = request.path

    if not request.query_string.blank?
      path += '?' + request.query_string
    elsif not request.env["rack.request.form_vars"].blank?
      path += '?' + request.env["rack.request.form_vars"]
    end
    if request.get?
      pass_to_backend path
    elsif request.post?
      allowed = false
      allowed = true if permissions.global_project_change

      #check for cmd parameter
      if params[:cmd].nil?
        render_error :status => 400, :errorcode => "missing_parameter",
          :message => "Missing parameter 'cmd'"
        return
      end

      unless ["wipe", "restartbuild", "killbuild", "abortbuild", "rebuild"].include? params[:cmd]
        render_error :status => 400, :errorcode => "illegal_request",
          :message => "unsupported POST command #{params[:cmd]} to #{request.request_uri}"
        return
      end

      if not allowed
        prj = DbProject.find_by_name( params[:project] ) 
        if prj.nil?
          render_error :status => 404, :errorcode => "not_found",
            :message => "Project does not exist #{params[:project]}"
          return
        end

        #check if user has project modify rights
        allowed = true if permissions.project_change? prj
      end

      if not allowed and not params[:package].nil?
        package_names = nil
        if params[:package].kind_of? Array
          package_names = params[:package]
        else
          package_names = [params[:package]]
        end
        package_names.each do |pack_name|
          pkg = DbPackage.find_by_project_and_name( prj.name, pack_name ) 
          if pkg.nil?
            allowed = permissions.project_change? prj
            if not allowed
              render_error :status => 403, :errorcode => "execute_cmd_no_permission",
                :message => "No permission to execute command on package #{pack_name} in project #{prj.name}"
              return
            end
          else
            allowed = permissions.package_change? pkg
            if not allowed
              render_error :status => 403, :errorcode => "execute_cmd_no_permission",
                :message => "No permission to execute command on package #{pack_name}"
              return
            end
          end
        end
      end

      if not allowed
        render_error :status => 403, :errorcode => "execute_cmd_no_permission",
          :message => "No permission to execute command on project #{params[:project]}"
        return
      end

      pass_to_backend path
      return
    elsif request.put? 
      if  @http_user.is_admin?
        pass_to_backend path
      else
        render_error :status => 403, :errorcode => "execute_cmd_no_permission",
          :message => "No permission to execute command on project #{params[:project]}"
      end
      return
    else
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: #{request.method.to_s.upcase} #{request.path}"
      return
    end
  end

  def buildinfo
    valid_http_methods :get, :post
    required_parameters :project, :repository, :arch, :package
    pkg = DbPackage.find_by_project_and_name params[:project], params[:package]

    # ACL(buildinfo): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    raise DbPackage::PkgAccessError.new "" if pkg.nil? or not DbPackage.check_access?(pkg)

    path = "/build/#{params[:project]}/#{params[:repository]}/#{params[:arch]}/#{params[:package]}/_buildinfo"
    unless request.query_string.empty?
      path += '?' + request.query_string
    end

    pass_to_backend path
  end

  # /build/:prj/:repo/:arch/:pkg
  # GET on ?view=cpio and ?view=cache unauthenticated and streamed
  # USED ??
  def package_index
    valid_http_methods :get
    required_parameters :project, :repository, :arch, :package
    pkg = DbPackage.find_by_project_and_name params[:project], params[:package]

    # ACL(package_index): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    raise DbPackage::PkgAccessError.new "" if pkg.nil? or not DbPackage.check_access?(pkg)

    pass_to_backend
  end

  # /build/:project/:repository/:arch/:package/:filename
  def file
    valid_http_methods :get, :delete
    required_parameters :project, :repository, :arch, :package, :filename

    if not params[:package] == "_repository"
      pkg = DbPackage.find_by_project_and_name params[:project], params[:package]
      raise DbPackage::PkgAccessError.new "" if pkg.nil? or not DbPackage.check_access?(pkg)
      end
    if pkg and not DbProject.find_remote_project params[:project]
      # ACL(file): binarydownload denies access to build files
      if pkg.disabled_for?('binarydownload', params[:repository], params[:arch]) and not @http_user.can_download_binaries?(pkg)
        render_error :status => 403, :errorcode => "download_binary_no_permission",
        :message => "No permission to download binaries from package #{params[:package]}, project #{params[:project]}"
        return
      end
    end

    path = request.path+"?"+request.query_string

    if request.delete?
      unless permissions.project_change? params[:project]
        render_error :status => 403, :errorcode => "delete_binary_no_permission",
          :message => "No permission to delete binaries from project #{params[:project]}"
        return
      end

      if params[:package] == "_repository"
        pass_to_backend
      else
        render_error :status => 400, :errorcode => "invalid_operation",
          :message => "Delete operation of build results is not allowed"
      end

      return
    end

    regexp = nil
    # if there is a query, we can't assume it's a simple download, so better leave out the logic (e.g. view=fileinfo)
    unless request.query_string
      #check if binary exists and for size
      fpath = "/build/"+[:project,:repository,:arch,:package].map {|x| params[x]}.join("/")
      file_list = Suse::Backend.get(fpath)
      regexp = file_list.body.match(/name=["']#{Regexp.quote params[:filename]}["'].*size=["']([^"']*)["']/)
    end
    if regexp
      fsize = regexp[1]
      logger.info "streaming #{path}"

      c_type = case params[:filename].split(/\./)[-1]
               when "rpm"
                 "application/x-rpm"
               when "deb"
                 "application/x-deb"
               when "iso"
                 "application/x-cd-image"
               else
                 "application/octet-stream"
               end

      headers.update(
        'Content-Disposition' => %(attachment; filename="#{params[:filename]}"),
        'Content-Type' => c_type,
        'Transfer-Encoding' => 'binary',
        'Content-Length' => fsize
      )
      
      render :status => 200, :text => Proc.new {|request,output|
        backend_request = Net::HTTP::Get.new(path)
        Net::HTTP.start(SOURCE_HOST,SOURCE_PORT) do |http|
          http.request(backend_request) do |response|
            response.read_body do |chunk|
              output.write(chunk)
            end
          end
        end
      }
    else
      pass_to_backend path
    end
  end

  def logfile
    valid_http_methods :get
    prj = DbProject.find_by_name params[:project]
    raise DbProject::PrjAccessError.new "" if prj.nil? or not DbProject.check_access?(prj)

    pkg = prj.find_package params[:package]

    raise DbPackage::PkgAccessError.new "" if pkg.nil? or not DbPackage.check_access?(pkg)

    # ACL(logfile): binarydownload denies logfile access
    if pkg.disabled_for?('binarydownload', params[:repository], params[:arch]) and not @http_user.can_download_binaries?(pkg)
      render_error :status => 403, :errorcode => "download_binary_no_permission",
        :message => "No permission to download logfile for package #{params[:package]}, project #{params[:project]}"
      return
    end

    # ACL(logfile): sourceaccess denies logfile access
    if pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
        :message => "No permission to download logfile for package #{params[:package]}, project #{params[:project]}"
      return
    end

    pass_to_backend
  end

  def result
    valid_http_methods :get
    prj = DbProject.find_by_name params[:project]

    raise DbProject::PrjAccessError.new "" if prj.nil? or not DbProject.check_access?(prj)

    pass_to_backend
  end

end
