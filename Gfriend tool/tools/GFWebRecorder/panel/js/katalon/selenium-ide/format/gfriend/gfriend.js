
/**
* Format TestCase and return the source.
*
* @param testCase TestCase to format
* @param name The name of the test case, if any. It may be used to embed title into the source.
*/
function format(testCase, name) {
  this.log.info("formatting testCase: " + name);
  var result = "";
  var header = "";
  var footer = "";
  this.name = name;
  this.commandCharIndex = 0;
  if (this.formatHeader) {
      header = formatHeader(testCase);
  }
  result += header;
  this.commandCharIndex = header.length;
  testCase.formatLocal(this.name).header = header;
  result += formatCommands(testCase.commands);
  result += options.footer;
  return result;
}

function filterForRemoteControl(originalCommands) {
  var commands = [];
  for (var i = 0; i<originalCommands.length;i++)
  {
      var c = originalCommands[i];
      c1 = String(c);

      var index = c1.indexOf("|");
      var commandName = c1.substring(0, index-1);      
      var targetName = c1.substring(index+2);
      var valueName = null;

      if(targetName.indexOf("|") != -1){
        index = targetName.indexOf("|");        
        valueName = targetName.substring(index+2);
        targetName = targetName.substring(0, index-1);
      }
      
      commandName = commandName.replace(commandName, GFkeywords[commandName]);

      if(commandName == "undefined"){
        this.log.info("Fail to find matched command from GFriend: " + c1);
        c1 = "//\""+ c1 + "\" is ignored.";
      }
      else if (commandName == "Web.Append Text" && valueName.indexOf("KEY_ENTER") != -1) {
        c1 = commandName + "(" + targetName + ", \\n)";
      }
      else if(commandName == "Web.Close"){
        c1 = "//\""+ commandName + "\" is ignored.";
      }
      else if(valueName != null){
        c1 = commandName + "(" + targetName + "," + valueName +")";
      }
      else{
        c1 = commandName + "(" + targetName + ")";
      }
      
      if (c1.match("label="))
      {
          c1 = c1.replace(/label=/g,"");
      }

      commands.push(c1);
  }
  return commands;
}

function formatCommands(commands) {
  commands = filterForRemoteControl(commands);  
  var result = name + '\r\n{\r\n';
  for (var i = 0; i < commands.length; i++) {
      var command = commands[i];
      if (command != null && command != "undefined") {
        command = "    " + command + "\r\n";
        result += command;              
      }
  }
  return result;
}

function formatHeader(testCase) {
  var header = (options.getHeader ? options.getHeader() : options.header).
      replace(/\$\{baseURL\}/g, testCase.getBaseURL()).
      replace(/\$\{([a-zA-Z0-9_]+)\}/g, function(str, name) { return options[name]; });
  return header;
}

function testClassName(testName) {
  return testName.split(/[^0-9A-Za-z]+/).map(
      function (x) {
          return capitalize(x);
      }).join('');
}

this.remoteControl = true;
this.playable = false;

this.options = {
  version: "v1.86",
  receiver: "",
  environment: "firefox",
  indent: "2",
  initialIndents: '2',
  defaultExtension: 'txt'
};

this.configForm = 
  '<description>Variable for Selenium instance</description>' +
  '<textbox id="options_receiver" />' +
  '<description>Environment</description>' +
  '<textbox id="options_environment" />' +
  '<description>Indent</description>' +
  '<menulist id="options_indent"><menupopup>' +
  '<menuitem label="Tab" value="tab"/>' +
  '<menuitem label="1 space" value="1"/>' +
  '<menuitem label="2 spaces" value="2"/>' +
  '<menuitem label="3 spaces" value="3"/>' +
  '<menuitem label="4 spaces" value="4"/>' +
  '<menuitem label="5 spaces" value="5"/>' +
  '<menuitem label="6 spaces" value="6"/>' +
  '<menuitem label="7 spaces" value="7"/>' +
  '<menuitem label="8 spaces" value="8"/>' +
  '</menupopup></menulist>';




this.name = "Recorded Web Test";

options.header = 'using Web \r\n\r\n';

options.footer = '    Web.Close\r\n}';

this.GFkeywords = {
  "sendKeys" : "Web.Append Text",
  "open" : "Web.Open with Chrome",
  "click" : "Web.Click Object",
  "submit" : "Web.Submit",
  "type" : "Web.Set Text",
  "close" : "Web.Close"
};