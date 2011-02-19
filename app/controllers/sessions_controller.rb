class SessionsController < ApplicationController
  layout :app_layout

  def new
    @available_locales = I18n.available_locales.map { 
      |locale| [locale.to_s, I18n.t('language.title', :locale => locale) + " (#{locale})"]
    }.sort
      
    if request.post?
      logout_keeping_session!
      user = User.authenticate(params[:login], params[:password])
      if user && user.enabled
        EventLog.info("user.login.ok", { :login => user.login })
        self.current_user = user
        new_cookie_flag = (params[:remember_me] == "on")
        handle_remember_cookie! new_cookie_flag
        respond_to do |format|
          format.html { render :json => { :success => true } }
          format.iphone { redirect_to :controller => 'iphone/dashboard' }
        end
      else
        if user
          message =  t('login.locked_user')
          EventLog.error("user.login.locked_user", { :login => user.login })
        else
          message = t('login.bad_login')
          known_user = User.find_by_login(params[:login])
          if known_user
            EventLog.error("user.login.bad_password", { :login => known_user.login })
          else
            EventLog.error("user.login.bad_login")
          end
        end

        logger.warn "Failed login for '#{params[:login]}' from #{request.remote_ip} at #{Time.now.utc}"
        respond_to do |format|
          format.html { render :json => { :success => false, :message => message } }
          format.iphone { flash.now[:error] = message }
        end
      end
    else
      respond_to do |format|
        format.html { redirect_to :controller => 'admin/dashboard' if logged_in? }
        format.iphone do
          redirect_to :controller => 'iphone/dashboard' if logged_in?
        end
      end
    end
    
    @page_title = t('login.page_title') if iphone?
  end

  def destroy
    EventLog.info("user.logout", { :login => current_user.login }) if current_user
    logout_killing_session!
    redirect_back_or_default('/')
  end
  
  private
  
    def app_layout
      iphone? ? 'iphone' : 'application'
    end
  
end
