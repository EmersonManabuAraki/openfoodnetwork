require 'action_callbacks'

module Spree
  module Admin
    class ResourceController < Spree::Admin::BaseController
      helper_method :new_object_url, :edit_object_url, :object_url, :collection_url
      before_filter :load_resource, except: [:update_positions]
      rescue_from ActiveRecord::RecordNotFound, with: :resource_not_found
      rescue_from CanCan::AccessDenied, with: :unauthorized

      respond_to :html
      respond_to :js, except: [:show, :index]

      def new
        invoke_callbacks(:new_action, :before)
        respond_with(@object) do |format|
          format.html { render layout: !request.xhr? }
          format.js   { render layout: false }
        end
      end

      def edit
        respond_with(@object) do |format|
          format.html { render layout: !request.xhr? }
          format.js   { render layout: false }
        end
      end

      def update
        invoke_callbacks(:update, :before)
        if @object.update_attributes(permitted_resource_params)
          invoke_callbacks(:update, :after)
          flash[:success] = flash_message_for(@object, :successfully_updated)
          respond_with(@object) do |format|
            format.html { redirect_to location_after_save }
            format.js   { render layout: false }
          end
        else
          invoke_callbacks(:update, :fails)
          respond_with(@object)
        end
      end

      def create
        invoke_callbacks(:create, :before)
        @object.attributes = permitted_resource_params
        if @object.save
          invoke_callbacks(:create, :after)
          flash[:success] = flash_message_for(@object, :successfully_created)
          respond_with(@object) do |format|
            format.html { redirect_to location_after_save }
            format.js   { render layout: false }
          end
        else
          invoke_callbacks(:create, :fails)
          respond_with(@object)
        end
      end

      def update_positions
        params[:positions].each do |id, index|
          model_class.where(id: id).update_all(position: index)
        end

        respond_to do |format|
          format.js { render text: 'Ok' }
        end
      end

      def destroy
        invoke_callbacks(:destroy, :before)
        if @object.destroy
          invoke_callbacks(:destroy, :after)
          flash[:success] = flash_message_for(@object, :successfully_removed)
          respond_with(@object) do |format|
            format.html { redirect_to collection_url }
            format.js   { render partial: "spree/admin/shared/destroy" }
          end
        else
          invoke_callbacks(:destroy, :fails)
          respond_with(@object) do |format|
            format.html { redirect_to collection_url }
          end
        end
      end

      protected

      def resource_not_found
        flash[:error] = flash_message_for(model_class.new, :not_found)
        redirect_to collection_url
      end

      class << self
        attr_accessor :parent_data
        attr_accessor :callbacks

        def belongs_to(model_name, options = {})
          @parent_data ||= {}
          @parent_data[:model_name] = model_name
          @parent_data[:model_class] = model_name.to_s.classify.constantize
          @parent_data[:find_by] = options[:find_by] || :id
        end

        def new_action
          @callbacks ||= {}
          @callbacks[:new_action] ||= ActionCallbacks.new
        end

        def create
          @callbacks ||= {}
          @callbacks[:create] ||= ActionCallbacks.new
        end

        def update
          @callbacks ||= {}
          @callbacks[:update] ||= ActionCallbacks.new
        end

        def destroy
          @callbacks ||= {}
          @callbacks[:destroy] ||= ActionCallbacks.new
        end
      end

      def model_class
        "Spree::#{controller_name.classify}".constantize
      end

      def model_name
        parent_data[:model_name].gsub('spree/', '')
      end

      def object_name
        controller_name.singularize
      end

      def load_resource
        if member_action?
          @object ||= load_resource_instance

          # call authorize! a third time (called twice already in Admin::BaseController)
          # this time we pass the actual instance so fine-grained abilities can control
          # access to individual records, not just entire models.
          authorize! action, @object

          instance_variable_set("@#{object_name}", @object)

          # If we don't have access, clear the object
          unless can? action, @object
            instance_variable_set("@#{object_name}", nil)
          end

          authorize! action, @object
        else
          @collection ||= collection

          # note: we don't call authorize here as the collection method should use
          # CanCan's accessible_by method to restrict the actual records returned

          instance_variable_set("@#{controller_name}", @collection)
        end
      end

      def load_resource_instance
        if new_actions.include?(action)
          build_resource
        elsif params[:id]
          find_resource
        end
      end

      def parent_data
        self.class.parent_data
      end

      def parent
        return nil if parent_data.blank?

        @parent ||= parent_data[:model_class].
          public_send("find_by_#{parent_data[:find_by]}", params["#{model_name}_id"])
        instance_variable_set("@#{model_name}", @parent)
      end

      def find_resource
        if parent_data.present?
          parent.public_send(controller_name).find(params[:id])
        else
          model_class.find(params[:id])
        end
      end

      def build_resource
        if parent_data.present?
          parent.public_send(controller_name).build
        else
          model_class.new
        end
      end

      def collection
        return parent.public_send(controller_name) if parent_data.present?

        if model_class.respond_to?(:accessible_by) &&
           !current_ability.has_block?(params[:action], model_class)
          model_class.accessible_by(current_ability, action)
        else
          model_class.scoped
        end
      end

      def location_after_save
        collection_url
      end

      def invoke_callbacks(action, callback_type)
        callbacks = self.class.callbacks || {}
        return if callbacks[action].nil?

        case callback_type.to_sym
        when :before then callbacks[action].before_methods.each { |method| __send__ method }
        when :after  then callbacks[action].after_methods.each  { |method| __send__ method }
        when :fails  then callbacks[action].fails_methods.each  { |method| __send__ method }
        end
      end

      # URL helpers

      def new_object_url(options = {})
        if parent_data.present?
          spree.new_polymorphic_url([:admin, parent, model_class], options)
        else
          spree.new_polymorphic_url([:admin, model_class], options)
        end
      end

      def edit_object_url(object, options = {})
        if parent_data.present?
          spree.public_send "edit_admin_#{model_name}_#{object_name}_url", parent, object, options
        else
          spree.public_send "edit_admin_#{object_name}_url", object, options
        end
      end

      def object_url(object = nil, options = {})
        target = object || @object
        if parent_data.present?
          spree.public_send "admin_#{model_name}_#{object_name}_url", parent, target, options
        else
          spree.public_send "admin_#{object_name}_url", target, options
        end
      end

      # Permit specific list of params
      #
      # Example: params.require(object_name).permit(:name)
      def permitted_resource_params
        raise "All extending controllers need to override the method permitted_resource_params"
      end

      def collection_url(options = {})
        if parent_data.present?
          spree.polymorphic_url([:admin, parent, model_class], options)
        else
          spree.polymorphic_url([:admin, model_class], options)
        end
      end

      def collection_actions
        [:index]
      end

      def member_action?
        !collection_actions.include? action
      end

      def new_actions
        [:new, :create]
      end
    end
  end
end
