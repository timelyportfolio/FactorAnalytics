# merge.lists from RCurl to avoid dependency not available in webr
merge.list <- function (x, y, ...) {
  if (length(x) == 0)
      return(y)
  if (length(y) == 0)
      return(x)
  i = match(names(y), names(x))
  i = is.na(i)
  if (any(i))
      x[names(y)[which(i)]] = y[which(i)]
  x
}

