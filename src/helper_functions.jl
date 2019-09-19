# #----------------------------------------------------------------------------------------------------------------------
# #----------------------------------------------------------------------------------------------------------------------
# This file contains functions and other snippets of code that are used in various calculations.
# #----------------------------------------------------------------------------------------------------------------------
# #----------------------------------------------------------------------------------------------------------------------


#######################################################################################################################
# CALCULATE REGIONAL CO₂ MITIGATION.
########################################################################################################################
# Description: This function calculates regional CO₂ mitigation levels as a function of a global carbon tax. It
#              uses the RICE2010 backstop price values and assumes a carbon tax of $0 in period 1.  If the number of
#              tax values is less than the total number of model time periods, the function assumes full decarbonization
#              (e.g. the tax = the backstop price) for all future periods without a specified tax.
#
# Function Arguments:
#
#       optimal_tax:    A vector of global carbon tax values to be optimized.
#       backstop_price: The regional backstop prices from RICE2010 (units must be in $1000s)
#       theta2:         The exponent on the abatement cost function (defaults to RICE2010 value).
#
# Function Output:
#
#       mitigation:     Regional mitigation rates resulting from the global carbon tax.
#----------------------------------------------------------------------------------------------------------------------

function mitigation_from_tax(optimal_tax::Array{Float64,1}, backstop_prices::Array{Float64,2}, theta2::Float64)

    # Initialize full tax vector with $0 tax in period 1 and maximum of the backstop price across all regions for remaining periods.
    full_tax = [0.0; maximum(backstop_prices, dims=2)[2:end]]

    # Set the periods being optimized to the optimized tax value (assuming full decarbonization for periods after optimization time frame).
    full_tax[2:(length(optimal_tax)+1)] = optimal_tax

    # Calculate regional mitigation rates from the full tax vector.
    mitigation = min.((max.(((full_tax ./ backstop_prices) .^ (1 / (theta2 - 1.0))), 0.0)), 1.0)

    return mitigation
end



#######################################################################################################################
# CREATE RICE OBJECTIVE FUNCTION.
########################################################################################################################
# Description: This function creates an objective function and an instance of RICE with user-specified parameter settings.
#              The objective function will take in a vector of global carbon tax values (cost-minimization) or regional
#              CO₂ mitigation rates (utilitarianism) and returns the total economic welfare generated by that specifc
#              climate policy.
#
# Function Arguments:
#
#       run_utilitarianism: A true/false indicator for whether or not to run the utilitarianism optimization (true = run utilitarianism).
#       ρ:                  Pure rate of time preference.
#       η:                  Elasticity of marginal utility of consumption.
#       backstop_prices:    The regional backstop prices from RICE2010 (units must be in dollars).
#       remove_negishi:     A true/false indicator for whether RICE should use a social welfare function with Negishi weights (true = remove Negishi weights).
#                           *Note: if using Negishi weights, RICE's discounting parameters default to η=1.5 and ρ=1.5%.
#
# Function Output:
#
#       rice_objective:     The objective function specific to user model settings.
#       m:                  An instance of RICE2010 consistent with user model settings.
#----------------------------------------------------------------------------------------------------------------------

function construct_rice_objective(run_utilitarianism::Bool, ρ::Float64, η::Float64, backstop_prices::Array{Float64,2}, remove_negishi::Bool)

    # Get an instance of RICE given user settings.
    m = create_rice(ρ, η, remove_negishi)

    #--------------------------------------------------------------------------------------------------------
    # Create either a (i) cost-minimization or (ii) utilitarian objective function for this instance of RICE.
    #--------------------------------------------------------------------------------------------------------
    rice_objective = if run_utilitarianism == false

        #---------------------------------------
        # Cost-minimizaton objective function.
        #---------------------------------------
        function(optimal_global_tax::Array{Float64,1})
            # Set the regional mitigation rates to the value implied by the global optimal carbon tax and return total welfare.
            set_param!(m, :emissions, :MIU, mitigation_from_tax(optimal_global_tax, backstop_prices, 2.8))
            run(m)
            return m[:welfare, :UTILITY]
        end

    else

        #---------------------------------------
        # Utilitarianism objective function.
        #---------------------------------------
        function(optimal_mitigation_vector::Array{Float64,1})
            # Number of periods with optimized rates (optimization program requires a vector).
            n_opt_periods = Int(length(optimal_mitigation_vector) / 12)
            # NOTE: for convenience, this objective directly optimizes the regional mitigation rates.
            # Initialze a regional mitigation array, assuming first period = 0% mitigation and periods after optimization achieve full decarbonization.
            optimal_regional_mitigation = vcat(zeros(1,12), ones(59,12))
            optimal_regional_mitigation[2:(n_opt_periods + 1), :] = reshape(optimal_mitigation_vector, (n_opt_periods, 12))
            # Set the optimal regional mitigation rates and return total welfare.
            set_param!(m, :emissions, :MIU, optimal_regional_mitigation)
            run(m)
            return m[:welfare, :UTILITY]
        end

    end

    # Return the newly created objective function and the specific instance of RICE.
    return rice_objective, m
end



#######################################################################################################################
# OPTIMIZE RICE.
########################################################################################################################
# Description: This function takes an objective function (given user-supplied model settings), and optimizes it for the
#              cost-minimization (global carbon taxes) or utilitarianism (regional carbon taxes) approach to find the
#              policy that maximizes global economic welfare. Note that the utilitarian objective function optimizes
#              on the decarbonization fraction (for more efficient code) and then calculates the corresponding regional
#              carbon tax values.
#
# Function Arguments:
#
#       optimization_algorithm:  The optimization algorithm to use from the NLopt package.
#       n_opt_periods:           The number of model time periods to optimize over.
#       stop_time:               The length of time (in seconds) for the optimization to run in case things do not converge.
#       tolerance:               Relative tolerance criteria for convergence (will stop if |Δf| / |f| < tolerance from one iteration to the next.)
#       backstop_price:          The regional backstop prices from RICE2010 (units must be in dollars).
#       run_utilitarianism:      A true/false indicator for whether or not to run the utilitarianism optimization (true = run utilitarianism).
#       ρ:                       Pure rate of time preference.
#       η:                       Elasticity of marginal utility of consumption.
#       remove_negishi:          A true/false indicator for whether RICE should use a social welfare function with Negishi weights (true = remove Negishi weights).
#
# Function Output
#
#       optimized_policy_vector: The vector of optimized policy values returned by the optimization algorithm.
#       optimal_mitigation:      Optimal mitigation rates for all time periods (2005-2595) resulting form the optimization.
#       opt_model:               An instance of RICE (with user-defined settings) set with the optimal CO₂ mitigation policy.
#----------------------------------------------------------------------------------------------------------------------


function optimize_rice(optimization_algorithm::Symbol, n_opt_periods::Int, stop_time::Int, tolerance::Float64, backstop_prices::Array{Float64,2}; run_utilitarianism::Bool=true, ρ::Float64=0.008, η::Float64=1.5, remove_negishi::Bool=true)

    # -------------------------------------------------------------
    # Create objective function and values needed for optimization.
    #--------------------------------------------------------------

    # Create objective function and instance of RICE, given user settings.
    objective_function, optimal_model = construct_rice_objective(run_utilitarianism, ρ, η, backstop_prices, remove_negishi)

    # Set objective function, upper bound, and number of optimzation objectives (will differ between cost-minimization and utilitarianism approaches).
    if run_utilitarianism == false
        # Number of objectives is equal to time periods being optimized.
        n_objectives = n_opt_periods
        # Upper bound is maximum of backstop price, across all regions.
        upper_bound = maximum(backstop_prices, dims=2)[2:(n_objectives+1)]
    else
        # Number of objectives is equal to time periods being optimizer × 12 regions.
        n_objectives = n_opt_periods * 12
        # Upper bound is 1.0 because we are optimizing the decarbonization rate (1 = full mitigation).
        upper_bound = ones(n_objectives)
    end

    # Create lower bound.
    lower_bound = zeros(n_objectives)

    # Create initial condition for algorithm (set at 50% of upper bound).
    starting_point = upper_bound/2

    # -------------------------------------------------------
    # Create an NLopt optimization object and optimize model.
    #--------------------------------------------------------
    opt = Opt(optimization_algorithm, n_objectives)

    # Set the bounds.
    lower_bounds!(opt, lower_bound)
    upper_bounds!(opt, upper_bound)

    # Assign the objective function to maximize.
    max_objective!(opt, (x, grad) -> objective_function(x))

    # Set termination time.
    maxtime!(opt, stop_time)

    # Set optimizatoin tolerance (will stop if |Δf| / |f| < tolerance from one iteration to the next).
    ftol_rel!(opt, tolerance)

    # Optimize model.
    maximum_objective_value, optimized_policy_vector, convergence_result = optimize(opt, starting_point)

    # Create optimal decarbonization rates for all time periods (approach to do so will differ between cost-minization and utilitarianism).
    if run_utilitarianism == false
        optimal_mitigation = mitigation_from_tax(optimized_policy_vector, backstop_prices, 2.8)
    else
        optimal_mitigation = vcat(zeros(1,12), ones(59,12))
        optimal_mitigation[2:(n_opt_periods+1), :] = reshape(optimized_policy_vector, (n_opt_periods, 12))
    end

    # Run user-specified version of RICE with optimal mitigation policy.
    set_param!(optimal_model, :emissions, :MIU, optimal_mitigation)
    run(optimal_model)

    # Create optimal tax rates for all time periods (approach to do so will differ between cost-minization and utilitarianism).
    if run_utilitarianism == false
        optimal_tax = [0.0; maximum(backstop_prices, dims=2)[2:end]]
        optimal_tax[2:(length(optimized_policy_vector)+1)] = optimized_policy_vector
    else
        optimal_tax = optimal_model[:emissions, :CPRICE]
    end

    # Return results of optimization, optimal mitigation rates, optimal taxes, and RICE run with optimal mitigation policies.
    return optimized_policy_vector, optimal_mitigation, optimal_tax, optimal_model
end
