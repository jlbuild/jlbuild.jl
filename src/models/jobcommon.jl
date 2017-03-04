# I don't know where else to put these code snippets
function update_status!(job)
    status = get_status(job)
    if status["status"] in ["canceled", "complete", "errored"]
        job.done = true
    end
    dbsave(job)
    return status["status"]
end

function get_status(job)
    return get_status(job.buildrequest_id)
end
