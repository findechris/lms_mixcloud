
var get_params = function(search_string) {

  var parse = function(params, pairs) {
    var pair = pairs[0];
    var parts = pair.split('=');
    var key = decodeURIComponent(parts[0]);
    var value = decodeURIComponent(parts.slice(1).join('='));

    // Handle multiple parameters of the same name
    if (typeof params[key] === "undefined") {
      params[key] = value;
    } else {
      params[key] = [].concat(params[key], value);
    }

    return pairs.length == 1 ? params : parse(params, pairs.slice(1))
  }

  // Get rid of leading ?
  return search_string.length == 0 ? {} : parse({}, search_string.substr(1).split('&'));
}

var params = get_params(location.search);
console.log(params);
var testurl = "https://www.mixcloud.com/oauth/authorize?client_id=Js32JMBmKGRg4zjHrY&redirect_uri=http://findechris.github.io/lms_mixcloud/";
if(params["code"]){
	var url = "https://www.mixcloud.com/oauth/access_token?client_id=Js32JMBmKGRg4zjHrY&redirect_uri=http://findechris.github.io/lms_mixcloud/&client_secret=E3uDXKnsMdWjxJMRtkY3e52JZfUAGnwM&code="+params["code"];
	$("#myparam").html('<a href="'+url+'">Get Token</a>');	
}else{
	$("#myparam").html(params["access_token"]);
}
