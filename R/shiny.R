#' Helper functions for using DT in Shiny
#'
#' These two functions are like most \code{fooOutput()} and \code{renderFoo()}
#' functions in the \pkg{shiny} package. The former is used to create a
#' container for table, and the latter is used in the server logic to render the
#' table.
#' @inheritParams shiny::dataTableOutput
#' @param width the width of the table container
#' @param height the height of the table container
#' @references \url{http://rstudio.github.io/DT/shiny.html}
#' @export
#' @examples # !formatR
#' if (interactive()) {
#'   library(shiny)
#'   shinyApp(
#'     ui = fluidPage(fluidRow(column(12, DT::dataTableOutput('tbl')))),
#'     server = function(input, output) {
#'       output$tbl = DT::renderDataTable(
#'         iris, options = list(lengthChange = FALSE)
#'       )
#'     }
#'   )
#' }
dataTableOutput = function(outputId, width = '100%', height = 'auto') {
  htmltools::attachDependencies(
    htmlwidgets::shinyWidgetOutput(
      outputId, 'datatables', width, height, package = 'DT'
    ),
    crosstalk::crosstalkLibs(),
    append = TRUE
  )
}

#' @export
#' @rdname dataTableOutput
#' @inheritParams shiny::renderDataTable
#' @param expr an expression to create a table widget (normally via
#'   \code{\link{datatable}()}), or a data object to be passed to
#'   \code{datatable()} to create a table widget
#' @param server whether to use server-side processing. If \code{TRUE}, then the
#'   data is kept on the server and the browser requests a page at a time; if
#'   \code{FALSE}, then the entire data frame is sent to the browser at once.
#'   Highly recommended for medium to large data frames, which can cause
#'   browsers to slow down or crash.
#' @param ... ignored when \code{expr} returns a table widget, and passed as
#'   additional arguments to \code{datatable()} when \code{expr} returns a data
#'   object
renderDataTable = function(expr, server = TRUE, env = parent.frame(), quoted = FALSE, ...) {
  if (!quoted) expr = substitute(expr)

  # TODO: this can be simplified after this htmlwidgets PR is merged
  # https://github.com/ramnathv/htmlwidgets/pull/122
  currentSession = NULL
  currentOutputName = NULL

  exprFunc = shiny::exprToFunction(expr, env, quoted = TRUE)
  widgetFunc = function() {
    instance = exprFunc()
    if (!all(c('datatables', 'htmlwidget') %in% class(instance))) {
      instance = datatable(instance, ...)
    } else if (length(list(...)) != 0) {
      warning("renderDataTable ignores ... arguments when expr yields a datatable object; see ?renderDataTable")
    }

    # in the server mode, we should not store the full data in JSON
    if (server && !is.null(instance[['x']])) {
      if (!is.null(instance$x$options$crosstalkOptions$group)) {
        stop("Crosstalk only works with DT client mode: DT::renderDataTable({...}, server=FALSE)")
      }

      origData = instance[['x']][['data']]
      instance$x$data = NULL

      # register the data object in a shiny session
      options = instance[['x']][['options']]

      # Normalize "ajax" argument; if we leave it a string then we have several
      # code paths that need to account for both string and list representations
      if (is.character(options[['ajax']])) {
        options$ajax = list(url = options$ajax)
      }

      if (is.null(options[['ajax']][['url']])) {
        url = sessionDataURL(currentSession, origData, currentOutputName, dataTablesFilter)
        options$ajax$url = url
      }
      instance$x$options = fixServerOptions(options)
    }

    instance
  }

  renderFunc = htmlwidgets::shinyRenderWidget(
    widgetFunc(), dataTableOutput, environment(), FALSE
  )

  shiny::markRenderFunction(dataTableOutput, function(shinysession, name, ...) {
    currentSession <<- shinysession
    currentOutputName <<- name
    on.exit({
      currentSession <<- NULL
      currentOutputName <<- NULL
    }, add = TRUE)

    renderFunc()
  })
}

#' Manipulate an existing DataTables instance in a Shiny app
#'
#' The function \code{datatableProxy()} creates a proxy object that can be used
#' to manipulate an existing DataTables instance in a Shiny app, e.g. select
#' rows/columns, or add rows.
#' @param outputId the id of the table to be manipulated (the same id as the one
#'   you used in \code{\link{dataTableOutput}()})
#' @param session the Shiny session object (from the server function of the
#'   Shiny app)
#' @param deferUntilFlush whether an action should be carried out right away, or
#'   should be held until after the next time all of the outputs are updated
#' @note \code{addRow()} only works for client-side tables. If you want to use
#'   it in a Shiny app, make sure to use \code{renderDataTable(..., server =
#'   FALSE)}.
#' @references \url{http://rstudio.github.io/DT/shiny.html}
#' @rdname proxy
#' @export
dataTableProxy = function(
  outputId, session = shiny::getDefaultReactiveDomain(), deferUntilFlush = TRUE
) {
  if (is.null(session))
    stop('datatableProxy() must be called from the server function of a Shiny app')

  structure(
    list(id = session$ns(outputId), session = session, deferUntilFlush = deferUntilFlush),
    class = 'datatableProxy'
  )
}

#' @param proxy a proxy object returned by \code{dataTableProxy()}
#' @param selected an integer vector of row/column indices, or a matrix of two
#'   columns (row and column indices, respectively) for cell indices; you may
#'   use \code{NULL} to clear existing selections
#' @rdname proxy
#' @export
selectRows = function(proxy, selected) {
  invokeRemote(proxy, 'selectRows', list(I(selected)))
}

#' @rdname proxy
#' @export
selectColumns = function(proxy, selected) {
  invokeRemote(proxy, 'selectColumns', list(I(selected)))
}

#' @rdname proxy
#' @export
selectCells = function(proxy, selected) {
  invokeRemote(proxy, 'selectCells', list(selected))
}

#' @param data a single row of data to be added to the table; it can be a matrix
#'   or data frame of one row, or a vector or list of row data (in the latter
#'   case, please be cautious about the row name: if your table contains row
#'   names, here \code{data} must also contain the row name as the first
#'   element)
#' @rdname proxy
#' @export
addRow = function(proxy, data) {
  if ((is.matrix(data) || is.data.frame(data)) && nrow(data) != 1)
    stop("'data' must be of only one row")
  invokeRemote(proxy, 'addRow', list(as.list(unname(data)), I(rownames(data))))
}

#' @rdname proxy
#' @export
clearSearch = function(proxy) {
  updateSearch(proxy, list(global = '', columns = ''))
}

#' @param page a number indicating the page to select
#' @rdname proxy
#' @export
selectPage = function(proxy, page) {
  invokeRemote(proxy, 'selectPage', list(page))
}

#' @param caption a new table caption (see the \code{caption} argument of
#'   \code{\link{datatable}()})
#' @rdname proxy
#' @export
updateCaption = function(proxy, caption) {
  invokeRemote(proxy, 'updateCaption', list(captionString(caption)))
}

#' @param keywords a list of two components: \code{global} is the global search
#'   keyword of a single character string (ignored if \code{NULL});
#'   \code{columns} is a character vector of the search keywords for all columns
#'   (when the table has one column for the row names, this vector of keywords
#'   should contain one keyword for the row names as well)
#' @rdname proxy
#' @export
updateSearch = function(proxy, keywords = list(global = NULL, columns = NULL)) {
  global = keywords$global
  if (is.null(global)) {
    keywords['global'] = list(NULL)
  } else {
    if (!is.character(global) || length(global) != 1)
      stop('keywords$global must be a character string')
  }
  columns = keywords$columns
  if (is.null(columns)) {
    keywords['columns'] = list(NULL)
  } else {
    if (is.character(columns)) {
      if (length(columns) == 0) stop(
        'The length of keywords$columns must be greater than zero if it is a character vector'
      )
    } else if (is.list(columns)) {
      if (any(sapply(columns, length) > 1)) stop(
        'keywords$columns should be a list of NULL or character strings'
      )
    } else stop('keywords$columns must be either a character vector or a list')
  }
  invokeRemote(proxy, 'updateSearch', list(keywords))
}

#' @param resetPaging whether to reset the paging position
#' @param clearSelection which existing selections to clear: it can be any
#'   combinations of \code{row}, \code{column}, and \code{cell}, or \code{all}
#'   for all three, or \code{none} to keep current selections (by default, all
#'   selections are cleared after the data is reloaded)
#' @note \code{reloadData()} only works for tables in the server-side processing
#'   mode, e.g. tables rendered with \code{renderDataTable(server = TRUE)}. The
#'   data to be reloaded (i.e. the one you pass to \code{dataTableAjax()}) must
#'   have exactly the same number of columns as the previous data object in the
#'   table.
#' @rdname proxy
#' @export
reloadData = function(
  proxy, resetPaging = TRUE, clearSelection = c('all', 'none', 'row', 'column', 'cell')
) {
  if ('all' %in% clearSelection) clearSelection = c('row', 'column', 'cell')
  invokeRemote(proxy, 'reloadData', list(resetPaging, clearSelection))
}

#' Replace data in an existing table
#'
#' Replace the data object of a table output and avoid regenerating the full
#' table, in which case the state of the current table will be preserved
#' (sorting, filtering, and pagination) and applied to the table with new data.
#' @param proxy a proxy object created by \code{dataTableProxy()}
#' @param data the new data object to be loaded in the table
#' @param ... other arguments to be passed to \code{\link{dataTableAjax}()}
#' @param resetPaging,clearSelection passed to \code{\link{reloadData}()}
#' @note When you replace the data in an existing table, please make sure the
#'   new data has the same number of columns as the current data. When you have
#'   enabled column filters, you should also make sure the attributes of every
#'   column remain the same, e.g. factor columns should have the same or fewer
#'   levels, and numeric columns should have the same or smaller range,
#'   otherwise the filters may never be able to reach certain rows in the data.
#' @export
replaceData = function(proxy, data, ..., resetPaging = TRUE, clearSelection = 'all') {
  dataTableAjax(proxy$session, data, ..., outputId = proxy$id)
  reloadData(proxy, resetPaging, clearSelection)
}

invokeRemote = function(proxy, method, args = list()) {
  if (!inherits(proxy, 'datatableProxy'))
    stop('Invalid proxy argument; table proxy object was expected')

  msg = list(id = proxy$id, call = list(method = method, args = args))

  sess = proxy$session
  if (proxy$deferUntilFlush) {
    sess$onFlushed(function() {
      sess$sendCustomMessage('datatable-calls', msg)
    }, once = TRUE)
  } else {
    sess$sendCustomMessage('datatable-calls', msg)
  }
  proxy
}

shinyFun = function(name) getFromNamespace(name, 'shiny')

#' Register a data object in a shiny session for DataTables
#'
#' This function stores a data object in a shiny session and returns a URL that
#' returns JSON data based on DataTables Ajax requests. The URL can be used as
#' the \code{url} option inside the \code{ajax} option of the table. It is
#' basically an implementation of server-side processing of DataTables in R.
#' Filtering, sorting, and pagination are processed through R instead of
#' JavaScript (client-side processing).
#'
#' Normally you should not need to call this function directly. It is called
#' internally when a table widget is rendered in a Shiny app to configure the
#' table option \code{ajax} automatically. If you are familiar with
#' \pkg{DataTables}' server-side processing, and want to use a custom filter
#' function, you may call this function to get an Ajax URL.
#' @param session the \code{session} object in the shiny server function
#'   (\code{function(input, output, session)})
#' @param data a data object (will be coerced to a data frame internally)
#' @param rownames see \code{\link{datatable}()}; it must be consistent with
#'   what you use in \code{datatable()}, e.g. if the widget is generated by
#'   \code{datatable(rownames = FALSE)}, you must also use
#'   \code{dataTableAjax(rownames = FALSE)} here
#' @param filter (for expert use only) a function with two arguments \code{data}
#'   and \code{params} (Ajax parameters, a list of the form \code{list(search =
#'   list(value = 'FOO', regex = 'false'), length = 10, ...)}) that return the
#'   filtered table result according to the DataTables Ajax request
#' @param outputId the output ID of the table (the same ID passed to
#'   \code{dataTableOutput()}; if missing, a random string)
#' @references \url{http://rstudio.github.io/DT/server.html}
#' @return A character string (an Ajax URL that can be queried by DataTables).
#' @example inst/examples/ajax-shiny.R
#' @export
dataTableAjax = function(session, data, rownames, filter = dataTablesFilter, outputId) {

  oop = options(stringsAsFactors = FALSE); on.exit(options(oop), add = TRUE)

  # abuse tempfile() to obtain a random id unique to this R session
  if (missing(outputId)) outputId = basename(tempfile(''))

  # deal with row names: rownames = TRUE or missing, use rownames(data)
  rn = if (missing(rownames) || isTRUE(rownames)) base::rownames(data) else {
    if (is.character(rownames)) rownames  # use custom row names
  }
  data = as.data.frame(data)  # think dplyr
  if (length(rn)) data = cbind(' ' = rn, data)

  sessionDataURL(session, data, outputId, filter)
}

sessionDataURL = function(session, data, id, filter) {

  URLdecode = shinyFun('URLdecode')
  toJSON = shinyFun('toJSON')
  httpResponse = shinyFun('httpResponse')

  filterFun = function(data, req) {
    # DataTables requests were sent via POST
    params = URLdecode(rawToChar(req$rook.input$read()))
    Encoding(params) = 'UTF-8'
    # use system native encoding if possible (again, this grep(fixed = TRUE) bug
    # https://bugs.r-project.org/bugzilla3/show_bug.cgi?id=16264)
    params2 = iconv(params, 'UTF-8', '')
    if (!is.na(params2)) params = params2 else warning(
      'Some DataTables parameters contain multibyte characters ',
      'that do not work in current locale.'
    )
    params = shiny::parseQueryString(params, nested = TRUE)

    res = tryCatch(filter(data, params), error = function(e) {
      list(error = as.character(e))
    })
    httpResponse(200, 'application/json', enc2utf8(toJSON(res, dataframe = 'rows')))
  }

  session$registerDataObj(id, data, filterFun)
}

# filter a data frame according to the DataTables request parameters
dataTablesFilter = function(data, params) {
  n = nrow(data)
  q = params
  ci = q$search[['caseInsensitive']] == 'true'
  # users may be updating the table too frequently
  if (length(q$columns) != ncol(data)) return(list(
    draw = as.integer(q$draw),
    recordsTotal = n,
    recordsFiltered = 0,
    data = list(),
    DT_rows_all = seq_len(n),
    DT_rows_current = list()
  ))

  # global searching
  i = logical(n)
  # for some reason, q$search might be NULL, leading to error `if (logical(0))`
  if (isTRUE(q$search[['value']] != '')) for (j in seq_len(ncol(data))) {
    if (q$columns[[j]][['searchable']] != 'true') next
    i0 = grep2(
      q$search[['value']], as.character(data[, j]),
      fixed = q$search[['regex']] == 'false', ignore.case = ci
    )
    i[i0] = TRUE
  } else i = !i
  i = which(i)

  # search by columns
  if (length(i)) for (j in names(q$columns)) {
    col = q$columns[[j]]
    # if the j-th column is not searchable or the search string is "", skip it
    if (col[['searchable']] != 'true') next
    if ((k <- col[['search']][['value']]) == '') next
    j = as.integer(j)
    dj = data[, j + 1]
    ij = if (is.numeric(dj) || is.Date(dj)) {
      which(filterRange(dj, k))
    } else if (is.factor(dj)) {
      which(dj %in% jsonlite::fromJSON(k))
    } else if (is.logical(dj)) {
      which(dj %in% as.logical(jsonlite::fromJSON(k)))
    } else {
      grep2(k, as.character(dj), fixed = col[['search']][['regex']] == 'false',
            ignore.case = ci)
    }
    i = intersect(ij, i)
    if (length(i) == 0) break
  }
  if (length(i) != n) data = data[i, , drop = FALSE]
  iAll = i  # row indices of filtered data

  # sorting
  oList = list()
  for (ord in q$order) {
    k = ord[['column']]  # which column to sort
    d = ord[['dir']]     # direction asc/desc
    if (q$columns[[k]][['orderable']] != 'true') next
    col = data[, as.integer(k) + 1]
    oList[[length(oList) + 1]] = (if (d == 'asc') identity else `-`)(
      if (is.numeric(col)) col else xtfrm(col)
    )
  }
  if (length(oList)) {
    i = do.call(order, oList)
    data = data[i, , drop = FALSE]
    iAll = iAll[i]
  }
  # paging
  if (q$length != '-1') {
    len = as.integer(q$length)
    # I don't know why this can happen, but see https://github.com/rstudio/DT/issues/164
    if (is.na(len)) {
      warning("The DataTables parameter 'length' is '", q$length, "' (invalid).")
      len = 0
    }
    i = seq(as.integer(q$start) + 1L, length.out = len)
    i = i[i <= nrow(data)]
    fdata = data[i, , drop = FALSE]  # filtered data
    iCurrent = iAll[i]
  } else {
    fdata = data
    iCurrent = iAll
  }

  if (q$escape != 'false') {
    k = seq_len(ncol(fdata))
    if (q$escape != 'true') {
      # q$escape might be negative indices, e.g. c(-1, -5)
      k = k[as.integer(strsplit(q$escape, ',')[[1]])]
    }
    for (j in k) if (maybe_character(fdata[, j])) fdata[, j] = htmlEscape(fdata[, j])
  }

  # TODO: if iAll is just 1:n, is it necessary to pass this vector to JSON, then
  # to R? When n is large, it may not be very efficient
  list(
    draw = as.integer(q$draw),
    recordsTotal = n,
    recordsFiltered = nrow(data),
    data = cleanDataFrame(fdata),
    DT_rows_all = iAll,
    DT_rows_current = iCurrent
  )
}

# when both ignore.case and fixed are TRUE, we use grep(ignore.case = FALSE,
# fixed = TRUE) to do lower-case matching of pattern on x
grep2 = function(pattern, x, ignore.case = FALSE, fixed = FALSE, ...) {
  if (fixed && ignore.case) {
    pattern = tolower(pattern)
    x = tolower(x)
    ignore.case = FALSE
  }
  # when the user types in the search box, the regular expression may not be
  # complete before it is sent to the server, in which case we do not search
  if (!fixed && inherits(try(grep(pattern, ''), silent = TRUE), 'try-error'))
    return(seq_along(x))
  grep(pattern, x, ignore.case = ignore.case, fixed = fixed, ...)
}

# filter a numeric/date/time vector using the search string "lower ... upper"
filterRange = function(d, string) {
  if (!grepl('[.]{3}', string) || length(r <- strsplit(string, '[.]{3}')[[1]]) > 2)
    stop('The range of a numeric / date / time column must be of length 2')
  if (length(r) == 1) r = c(r, '')  # lower,
  r = gsub('^\\s+|\\s+$', '', r)
  r1 = r[1]; r2 = r[2]
  if (is.numeric(d)) {
    r1 = as.numeric(r1); r2 = as.numeric(r2)
  } else if (inherits(d, 'Date')) {
    if (r1 != '') r1 = as.Date(r1)
    if (r2 != '') r2 = as.Date(r2)
  } else {
    if (r1 != '') r1 = as.POSIXct(r1, tz = 'GMT', '%Y-%m-%dT%H:%M:%S')
    if (r2 != '') r2 = as.POSIXct(r2, tz = 'GMT', '%Y-%m-%dT%H:%M:%S')
  }
  if (r[1] == '') return(d <= r2)
  if (r[2] == '') return(d >= r1)
  d >= r1 & d <= r2
}

# treat factors as characters
maybe_character = function(x) {
  is.character(x) || is.factor(x)
}

# make sure we have a tidy data frame (no unusual structures in it)
cleanDataFrame = function(x) {
  x = unname(x)  # remove column names
  if (!is.data.frame(x)) return(x)
  for (j in seq_len(ncol(x))) {
    xj = x[, j]
    xj = unname(xj)  # remove names
    dim(xj) = NULL  # drop dimensions
    if (is.table(xj)) xj = c(xj)  # drop the table class
    x[, j] = xj
  }
  unname(x)
}

fixServerOptions = function(options) {
  options$serverSide = TRUE
  if (is.null(options$processing)) options$processing = TRUE

  # if you generated the Ajax URL from dataTableAjax(), I'll configure type:
  # 'POST' and a few other options automatically
  if (!inShiny()) return(options)
  if (length(grep('^session/[a-z0-9]+/dataobj/', options$ajax$url)) == 0)
    return(options)

  if (is.null(options$ajax$type)) options$ajax$type = 'POST'
  if (is.null(options$ajax$data)) options$ajax$data = JS(
    'function(d) {',
    sprintf(
      'd.search.caseInsensitive = %s;',
      tolower(!isFALSE(options[['search']]$caseInsensitive))
    ),
    sprintf('d.escape = %s;', attr(options, 'escapeIdx', exact = TRUE)),
    'var encodeAmp = function(x) { x.value = x.value.replace(/&/g, "%26"); }',
    'encodeAmp(d.search);',
    '$.each(d.columns, function(i, v) {encodeAmp(v.search);});',
    '}'
  )
  options
}
