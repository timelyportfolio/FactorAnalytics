#' @title Functions to compute estimates and their standard errors using fmmc
#'
#' @details This method takes in the additional arguments list and checks if parameters
#' are set. Then it defaults values if they are unset. Currently it controls the
#' fit.method(default: OLS) and variable.selection(default: subsets). If
#' variable.selection is set to values other than subsets/none then it will
#' default to subsets.
#' arguments for FactorAnalytics
#'
#' @param  ... Arguments that must be passed to fitTsfm
#'
#'
.fmmc.default.args <- function(...) {
    add.args <- list(...)
    if(!"fit.method" %in% names(add.args)) add.args[["fit.method"]] <- "LS"

    if(!"variable.selection" %in% names(add.args))
        add.args[["variable.selection"]] <- "subsets"
    else {
        if(!add.args[["variable.selection"]] %in% c("none", "subsets"))
            add.args[["variable.selection"]] <- "subsets"
    }

    if (add.args[["variable.selection"]] == "subsets") {
        if(!"nvmax" %in% names(add.args))
            add.args[["nvmax"]] <- NA
    }

    add.args
}

#' @title Implementation of the Factor Model Monte Carlo method.
#'
#' @details Returns a fmmc object that contains the joint empirical density of factors and returns. This
#' fmmc object can be reused to for calculating risk and performance estimates along
#' with standard errors for the estimates
#'
#' This method takes in data, factors and residual type. It then does the following
#' 1. Fit a time series factor model to the data using user supplied selection and
#'    fit variables or it defaults them to stepwise and OLS respectively. If any
#'    of the betas are NA then the corresponding factors are dropped
#' 2. If the residual type besides empirical is specified then it fits the
#'    corresponding distribution to the residuals and simulates from the fitted
#'    distribution. The number of NA's in the simulated sample are the same as
#'    original residuals.
#' 3. It then merges factors and non-NA residuals for each asset to create a full
#'    outer join of the factors and residuals. We use this joined data to create new
#'    simulated returns. Returns together with factors define a joint empirical density.
#'
#' @importFrom xts as.xts
#'
#' @param  R single vector of returns
#' @param  factors matrix of factor returns
#' @param  ... allows passing parameters to FactorAnalytics.
#' @author Rohit Arora
#'
#'
.fmmc.proc <- function(R, factors ,... ) {

    # Check if the classes of Returns and factors are correct
    if(is.null(nrow(R)) || is.null(nrow(factors))) {
        warning("Inputs are not matrix")
        return(NA)
    }

    factors.data <- na.omit(factors)
    T <- nrow(factors.data); T1 <- nrow(R)
    if (T < T1) {
        warning("Length of factors cannot be less than assets")
        return(NA)
    }

    # Start getting ready to fit a time-series factor model to the data.
    .data <- as.matrix(merge(R,factors.data))

    #default args if not set
    add.args <- .fmmc.default.args(...)
    fit.method <- add.args[["fit.method"]]
    variable.selection <- add.args[["variable.selection"]]

    if(variable.selection == "subsets"  && is.na(add.args[["nvmax"]]))
         add.args[["nvmax"]] <-  floor((ncol(factors.data) - 1)/2)

    # Lets fit the time-series model
    args <- list(asset.names=colnames(R),
        factor.names=colnames(factors.data), data=.data)

    args <- merge.list(args,add.args)

    # We do not need to remove NA's. Beta's do no change if NA's are not removed
    possibleError <- tryCatch(
            fit <- do.call(fitTsfm, args),
        error=function(e)
            e)

    if(inherits(possibleError, "error")) {
        warning(paste("Timeseries model fitting failed for ", colnames(R)))
        return(NA)
    }

    resid <- do.call(merge, lapply(lapply(fit$asset.fit, residuals), xts::as.xts))
    beta <- t(fit$beta)

    if(any(is.na(beta))) {
        warning("some of the betas where NA in .fmmc.proc. Dropping those")
        beta <- beta[!is.na(c(beta)), 1, drop=FALSE]
        names.factors <- colnames(factors.data)
        names.beta    <- rownames(beta)
        factors.data <- as.matrix(factors.data[,names.factors %in% names.beta])
    }

    # define a joint empirical density for the factors and residuals and use
    # that to calculate the returns.
    .data <- as.matrix(merge(as.matrix(factors.data), resid))
    alpha <- matrix(as.numeric(fit$alpha), nrow=nrow(.data), ncol=1, byrow=TRUE)

    returns   <- alpha + .data[,-ncol(.data),drop=FALSE] %*% beta +
        .data[,ncol(.data),drop=FALSE]

    result <- list(bootdist = list(returns = returns,
        factors = .data[,-ncol(.data),drop=FALSE]),
        data = list(R = R, factors = factors.data), args = add.args)
    result
}

#' #' @title  Statistic function for the boot call.
#'
#' Calculates the risk or performance measure by using the estimation function in its argument list.
#'
#' @details
#' This method works as follows.
#' 1. Get data with factors and returns.
#' 2. Subset T rows from the data.
#' 3. Discard first TR-TR1 of the asset returns by setting them to NA
#' 4. calls .fmmc.proc method over the new data set to get a new joint empirical
#'    distribution of returns and factors
#' 5. We use the new returns with the estimation function to calculate the
#'    risk or performance measure.
#'
#' @param  data matrix of (all factors + returns of just 1 asset)
#' @param  indices row numbers generated by boot
#' @param  args additinal paramters needed for subsetting the data and calulating
#'         the perfomance/risk measure.
#' @author Rohit Arora
#'
#'
.fmmc.boot <- function(data, indices, args) {

    TR <- args$TR
    TR1 <- args$TR1
    estimate.func <- args$estimate.func
    fit.method <- args$fit.method
    var.sel <- args$var.sel

    fun <- match.fun(estimate.func)

    # we just need TR rows of data
    ind <- sample(indices, TR , replace = TRUE)
    data <- data[ind,]

    # discard the first (TR-TR1) portion of returns if using fmmc. For
    # complete data TR = TR1
    .data <- data
    .data[1:(TR-TR1),ncol(.data)] <- NA

    # If the data does not have dates then it cannot be transformed to xts.
    # So lets fake dates to make xts happy
    .data <- xts::as.xts(.data , order.by=seq(as.Date("1980/1/1"), by = "day",
        length.out = nrow(.data)))

    # lets get a new empirical distribution of factors and returns for a new subset
    fmmcObj <- .fmmc.proc(R=.data[,ncol(.data),drop=FALSE],
        factors=.data[,-ncol(.data)],
        fit.method = fit.method, variable.selection = var.sel)

    # lets calculate the performance or risk estimate
    measure <- fun(fmmcObj$bootdist$returns)
    measure
}

#' @title Main function to calculate the risk/performance estimate and calculate the
#' standard error of the estimate using bootstrapping.
#'
#' @details
#' bootstrapping in our  case can be painfully slow, so we exploit the parallel
#' capabilities of boot function. All cores on your machine are used.
#' We use the boot call from the boot library for calculating the estimate and
#' its standard error.
#'
#' @importFrom boot boot
#'
#' @param  fmmcObj object returned by fmmc proc. This is a comprehensive object
#'         with all data for factors and returns.
#' @param  nboot number of bootstap samples. Not sure how many repetations are
#'         reuired but remember bias-variance tradeoff. Increasing nboot will only
#'         reduce variance and not have a significant effect on bias(estimate)
#' @param  estimate.func this is a handle to the function used for calulating
#'         the perfomance/risk measure.
#' @param  cl A cluster for running across multiple cores
#' @author Rohit Arora
#'
#'
.fmmc.se <- function(fmmcObj, nboot = 50, estimate.func, cl = NULL) {

    parallel <- if(is.null(cl)) "no" else "snow"
    ncpus <- if(is.null(cl)) 1 else detectCores()

    # length of factors
    TR <- nrow(fmmcObj$data$factors)

    # length of the asset returns
    len <- nrow(fmmcObj$data$R) -
        apply(fmmcObj$data$R, 2, function(col) which.min(is.na(col))) + 1

    returns <- fmmcObj$bootdist$returns
    factors <- fmmcObj$bootdist$factors

    # no need to do variable selection again. So lets turn it off
    args <- list(TR = TR, TR1 = len, estimate.func = estimate.func,
        fit.method = fmmcObj$args[["fit.method"]], var.sel = "none")

    result <- boot::boot(data=cbind(factors, returns), statistic = .fmmc.boot,
        R = nboot, parallel = parallel, ncpus = ncpus, cl = cl, args=args)

    se <- apply(result$t,2,sd)
    se
}

#' @title Worker function that acts between the fmmc procedure and calling method.
#'
#' @details
#' This method takes in data as single time series and factors as xts objects
#' It then calls the actual estimation procedure.
#'
#' @param  R single vector of returns
#' @param  factors matrix of factor returns
#' @param  ... allows passing paramters to FactorAnalytics.
#' @author Rohit Arora
#'
#'
#'
.fmmc.worker <- function(R, factors, ...) {
    fmmc.obj <- .fmmc.proc(R=R, factors=factors, ...)
    fmmc.obj
}

#' @title  Compute fmmc objects that can be used for calcuation of estimates and their
#' standard errors
#'
#' @details
#' This method takes in data and factors as xts objects where multiple
#' time series with different starting dates are merged together. It then
#' computes FMMC objects as described in Jiang and Martin (2013)
#'
#' @param  R matrix of returns in xts format
#' @param  factors matrix of factor returns in xts format
#' @param  parallel flag to utilize multiplecores on the cpu. All cores are used.
#' @param  ... Arguments that must be passed to fitTsfm
#'
#' @return returns an list of fmmc objects
#'
#' @references
#' Yindeng Jiang and Richard Doug Martin. Better Risk and Performance
#' Estimates with Factor Model Monte Carlo. SSRN Electronic Journal, July 2013.
#'
#' @author Rohit Arora
#'
#' @import foreach
#' @importFrom doSNOW registerDoSNOW
#' @importFrom parallel makeCluster detectCores clusterEvalQ clusterExport stopCluster
#'
#' @export
#'
#'
fmmc <- function(R, factors, parallel=FALSE, ...) {

  ret <- NA
  assets.count <- ncol(R)
  i <- NA

  if (parallel) {
    cl <- makeCluster(detectCores())
    registerDoSNOW(cl)
    ret <- foreach (i = 1:assets.count) %dopar% .fmmc.worker(R[,i], factors, ...)
    stopCluster(cl)
  } else
    ret <- foreach (i = 1:assets.count) %do% .fmmc.worker(R[,i], factors, ...)

  result <- ret[lapply(ret,length) > 1]
  result
}

#' @title Main function to calculate the standard errror of the estimate
#'
#' @details
#' This method takes in a list of fmmc objects and a callback function to compute
#' an estimate. The first argument of the callback function must be the data
#' bootstrapped using fmmc procedure. The remaining arguments can be suitably
#' bound to the parameters as needed. This function can also be used to calculate
#' the standard error using the se flag.
#'
#' @param  fmmcObjs A list of fmmc objects computed using .fmmc.proc and containing
#'          bootstrapped returns
#' @param  fun A callback function where the first argument is returns and all the
#'          other arguments are bounded to values
#' @param  se A flag to indicate if standard error for the estimate must be calculated
#' @param  parallel A flag to indicate if multiple cpu cores must be used
#' @param  nboot Number of bootstrap samples
#'
#' @return returns the estimates and thier standard errors given fmmc objects
#'
#' @author Rohit Arora
#' @export
#'
fmmc.estimate.se <- function(fmmcObjs, fun=NULL, se=FALSE, nboot=100,
                             parallel = FALSE) {

    result <- as.matrix(rep(NA, length(fmmcObjs))); colnames(result) <- "estimate"
    rownames(result) <- unlist(lapply(fmmcObjs, function(obj) colnames(obj$data$R)))

    if(is.null(fun)) return(result)

    cl <- NULL
    if(parallel) {
        cl <- makeCluster(detectCores())
        clusterEvalQ(cl, library(xts))
    }

    result[,1] <- unlist(lapply(fmmcObjs, function(obj) fun(obj$bootdist$returns)))
    if(se) {
        serr <- unlist(
            lapply(fmmcObjs, function(obj) .fmmc.se(obj, nboot, fun, cl)))
        result <- cbind(result, serr)
        colnames(result) <- c("estimate", "se")
    }

    if(parallel) stopCluster(cl)

    result
}
