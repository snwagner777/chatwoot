module OperatorThemeConcern
  private

  def validate_operator_theme
    return unless params.key?(:operator_theme)
    return if ['', 'economyops'].include?(params[:operator_theme])

    render json: { error: 'Invalid operator theme' }, status: :unprocessable_entity
  end

  def apply_operator_theme
    return unless params.key?(:operator_theme)

    if params[:operator_theme].blank?
      @account.custom_attributes.delete('operator_theme')
    else
      @account.custom_attributes['operator_theme'] = params[:operator_theme]
    end
  end
end
